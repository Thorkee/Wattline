import Darwin
import Foundation
import os

enum InventoryScope: Hashable, Sendable {
    case apps
    case folder(URL)
}

struct StorageEntry: Identifiable, Sendable {
    let url: URL
    let bytes: UInt64
    let isPartial: Bool
    let isScanning: Bool

    var id: URL { url }
}

struct InventoryUpdate: Sendable {
    let entries: [StorageEntry]
    let isComplete: Bool
    let hasSkippedItems: Bool
    var directFileBytes: UInt64? = nil
    var reachedScanLimit = false
    var skippedNetworkVolume = false
    var measuredItemCount: Int? = nil
    var measuredBytes: UInt64? = nil
}

struct StorageScanLimits: Sendable {
    var maxEntries = 100_000
    var maxDuration: TimeInterval = 15
}

enum StorageInventory {
    static func scan(_ scope: InventoryScope, applicationDirectories: [URL]? = nil,
                     limits: StorageScanLimits = .init()) -> AsyncStream<InventoryUpdate> {
        StorageInventorySession(scope, applicationDirectories: applicationDirectories, limits: limits).nextBatch()
    }
}

final class StorageInventorySession: @unchecked Sendable {
    // Serialize even across sessions. A replacement scan never competes with its cancelled predecessor.
    private static let worker = DispatchQueue(label: "local.wattline.storage-inventory", qos: .background)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    private let limits: StorageScanLimits
    private let mountTable: @Sendable () -> StorageMountFilter?
    private var walk: InventoryWalk? // Accessed only on worker until deinit.

    init(_ scope: InventoryScope, applicationDirectories: [URL]? = nil, limits: StorageScanLimits = .init(),
         mountTable: @escaping @Sendable () -> StorageMountFilter? = { StorageMountFilter.current() }) {
        self.limits = limits
        self.mountTable = mountTable
        walk = InventoryWalk(scope, applicationDirectories: applicationDirectories)
    }

    func cancel() {
        let alreadyCancelled = cancelled.withLock { previous in
            let wasCancelled = previous
            previous = true
            return wasCancelled
        }
        if !alreadyCancelled { Self.worker.async { self.walk = nil } }
    }

    func nextBatch() -> AsyncStream<InventoryUpdate> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let delivered = OSAllocatedUnfairLock(initialState: false)
            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason, !delivered.withLock({ $0 }) { self?.cancel() }
            }
            Self.worker.async { [self] in
                defer { continuation.finish() }
                guard let walk, !cancelled.withLock({ $0 }) else { return }
                // Thread-scoped kernel policies must be restored before libdispatch reuses the thread.
                let disk = IOPOL_TYPE_DISK
                let hydrate = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
                let trigger = IOPOL_TYPE_VFS_TRIGGER_RESOLVE
                let previousTrigger = getiopolicy_np(trigger, IOPOL_SCOPE_THREAD)
                let changedTrigger = previousTrigger >= 0 && setiopolicy_np(trigger, IOPOL_SCOPE_THREAD, IOPOL_VFS_TRIGGER_RESOLVE_OFF) == 0
                let previousDisk = getiopolicy_np(disk, IOPOL_SCOPE_THREAD)
                let previousHydration = getiopolicy_np(hydrate, IOPOL_SCOPE_THREAD)
                let changedDisk = previousDisk >= 0 && setiopolicy_np(disk, IOPOL_SCOPE_THREAD, IOPOL_UTILITY) == 0
                let changedHydration = previousHydration >= 0 &&
                    setiopolicy_np(hydrate, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
                defer {
                    if changedHydration { setiopolicy_np(hydrate, IOPOL_SCOPE_THREAD, previousHydration) }
                    if changedTrigger { setiopolicy_np(trigger, IOPOL_SCOPE_THREAD, previousTrigger) }
                    if changedDisk { setiopolicy_np(disk, IOPOL_SCOPE_THREAD, previousDisk) }
                }
                let info = ProcessInfo.processInfo
                let start = info.systemUptime
                let deadline = start + max(0, limits.maxDuration)
                if !walk.finished { walk.refreshMounts(mountTable()) }
                var lastPublish = start
                var lastRest = start
                var steps = 0
                while !walk.finished {
                    if cancelled.withLock({ $0 }) { return }
                    let now = info.systemUptime
                    guard steps < limits.maxEntries, now < deadline else { break }
                    if now - lastPublish >= 0.45 {
                        continuation.yield(walk.snapshot(terminal: false, limited: false))
                        lastPublish = now
                    }
                    if now - lastRest >= 0.024 {
                        let constrained = info.isLowPowerModeEnabled || info.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
                        Thread.sleep(forTimeInterval: constrained ? 0.024 : 0.004)
                        lastRest = info.systemUptime
                        continue
                    }
                    walk.step()
                    steps += 1
                }
                guard !cancelled.withLock({ $0 }) else { return }
                delivered.withLock { $0 = true }
                continuation.yield(walk.snapshot(terminal: true, limited: !walk.finished))
            }
        }
    }
}

// The cached kernel mount table can be read without polling mounted network servers.
struct StorageMountFilter: Sendable {
    private let remote: Set<String>
    private let mountpoints: Set<String>
    private var ancestors = Set<String>()

    init(excludedPaths: [String], localMountPaths: [String] = []) {
        self.remote = Self.aliases(for: excludedPaths)
        self.mountpoints = remote.union(Self.aliases(for: localMountPaths))
        for path in mountpoints {
            var parent = path
            while parent != "/" && !parent.isEmpty {
                parent = (parent as NSString).deletingLastPathComponent
                ancestors.insert(parent)
            }
        }
    }

    private static func aliases(for paths: [String]) -> Set<String> {
        let data = "/System/Volumes/Data"
        var result = Set(paths)
        for path in paths where path != data && path != "/" {
            if path.hasPrefix(data + "/") {
                result.insert(String(path.dropFirst(data.count)))
            } else if path.hasPrefix("/") {
                result.insert(data + path)
            }
        }
        return result
    }

    func excludes(_ path: String) -> Bool {
        var next = path
        while !next.isEmpty {
            if remote.contains(next) { return true }
            if next == "/" { return false }
            next = (next as NSString).deletingLastPathComponent
        }
        return false
    }

    fileprivate func branch(_ path: String) -> String? { ancestors.contains(path) ? path : nil }
    fileprivate func isMount(_ path: String) -> Bool { mountpoints.contains(path) }
    fileprivate func isRemoteMount(_ path: String) -> Bool { remote.contains(path) }

    fileprivate static func current() -> Self? {
        let count = Int(getfsstat(nil, 0, MNT_NOWAIT))
        guard count > 0, count < 8192 else { return nil }
        var records = Array(repeating: statfs(), count: count + 16)
        let capacity = records.count
        let loaded = records.withUnsafeMutableBufferPointer {
            Int(getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT))
        }
        guard loaded > 0, loaded < capacity else { return nil }
        var remote = [String]()
        var local = [String]()
        for i in 0..<loaded {
            let path = withUnsafeBytes(of: &records[i].f_mntonname) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            let fs = withUnsafeBytes(of: &records[i].f_fstypename) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            if (records[i].f_flags & UInt32(MNT_LOCAL)) == 0 || fs == "autofs" {
                remote.append(path)
            } else {
                local.append(path)
            }
        }
        return Self(excludedPaths: remote, localMountPaths: local)
    }

    // Resolve intermediate symlinks one component at a time, checking the cached mounts
    // before *each* metadata call. Leave a final symlink for the root's no-follow check.
    fileprivate func localRoot(_ input: String, excludedVolume: inout Bool) -> String? {
        guard input.hasPrefix("/") else { return nil }
        if isRemoteMount("/") { excludedVolume = true; return nil }
        var pending = input.split(separator: "/").reversed().map(String.init)
        var parts = [String]()
        var followed = 0
        while let component = pending.popLast() {
            if component == "." { continue }
            if component == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(component)
            let path = "/" + parts.joined(separator: "/")
            if isRemoteMount(path) { excludedVolume = true; return nil }
            guard !pending.isEmpty else { break }
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            if info.st_mode & S_IFMT == S_IFLNK {
                followed += 1
                guard followed <= 32 else { return nil }
                var bytes = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let length = readlink(path, &bytes, Int(PATH_MAX))
                guard length > 0, length < Int(PATH_MAX) else { return nil }
                let target = String(cString: bytes)
                parts.removeLast()
                if target.hasPrefix("/") { parts.removeAll() }
                pending.append(contentsOf: target.split(separator: "/").reversed().map(String.init))
            }
        }
        return "/" + parts.joined(separator: "/")
    }
}

private struct FileID: Hashable {
    let volume: dev_t
    let inode: ino_t

    init(_ info: stat) {
        volume = info.st_dev
        inode = info.st_ino
    }
}

// Each cursor owns one already-open directory. A suspended batch has no running thread.
// readdir streams directory records; fts_read can stat every sibling before returning once.
private final class DirectoryCursor {
    enum Role { case discovery, itemRoot, descendant }

    let stream: UnsafeMutablePointer<DIR>
    let role: Role
    let volume: dev_t
    let discoveryURL: URL?
    let component: String
    var mountBranch: String?

    init?(_ name: UnsafePointer<CChar>, relativeTo parent: Int32, expected: stat, role: Role, discoveryURL: URL?, mountBranch: String?) {
        guard expected.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        var opened = stat()
        guard fstat(fd, &opened) == 0, FileID(opened) == FileID(expected),
              opened.st_flags & UInt32(SF_DATALESS) == 0, let stream = fdopendir(fd) else {
            close(fd)
            return nil
        }
        self.stream = stream
        self.role = role
        self.volume = opened.st_dev
        self.discoveryURL = discoveryURL
        self.component = String(cString: name)
        self.mountBranch = mountBranch
    }

    deinit { closedir(stream) }
}

private final class InventoryWalk {
    private static let maxDepth = 48
    private static let maxRanked = 256
    private static let maxIDs = 16_384
    private let apps: Bool
    private let roots: [URL]
    private var nextRoot = 0
    private var stack = [DirectoryCursor]()
    private var appIDs = Set<FileID>()
    private var directLinks = Set<FileID>()
    private var directBytes: UInt64 = 0
    private var ranked = [StorageEntry]()
    private var worstRank = 0
    private var itemCount = 0
    private var totalBytes: UInt64 = 0
    private var totalLinks = Set<FileID>()
    private var skipped = false
    private var skippedNetwork = false
    private var mounts: StorageMountFilter?
    private var currentURL: URL?
    private var currentBytes: UInt64 = 0
    private var currentPartial = false
    private var currentLinks = Set<FileID>()

    init(_ scope: InventoryScope, applicationDirectories: [URL]?) {
        switch scope {
        case .apps:
            apps = true
            roots = applicationDirectories ?? [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
                URL(fileURLWithPath: "/System/Applications", isDirectory: true)
            ]
        case .folder(let url):
            apps = false
            roots = [url]
        }
    }

    var finished: Bool { stack.isEmpty && nextRoot == roots.count }

    func refreshMounts(_ mounts: StorageMountFilter?) {
        self.mounts = mounts
        guard let mounts else {
            // No trustworthy local/remote boundary. Keep the measurements already obtained.
            markSkipped()
            if currentURL != nil { finishItem() }
            stack.removeAll()
            nextRoot = roots.count
            return
        }
        var branch: String?
        for (index, cursor) in stack.enumerated() {
            if index == 0 { branch = mounts.branch(cursor.component) }
            else if let parent = branch { branch = mounts.branch(Self.join(parent, cursor.component)) }
            cursor.mountBranch = branch
        }
    }

    private static func join(_ directory: String, _ component: String) -> String {
        directory == "/" ? "/" + component : directory + "/" + component
    }

    func step() {
        guard let parent = stack.last else {
            let root = roots[nextRoot]
            nextRoot += 1
            openRoot(root)
            return
        }
        errno = 0
        guard let entry = readdir(parent.stream) else {
            if errno != 0 { markSkipped() }
            stack.removeLast()
            if parent.role == .itemRoot { finishItem() }
            return
        }
        withUnsafePointer(to: &entry.pointee.d_name) { field in
            field.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { name in
                if name[0] == 46, name[1] == 0 || (name[1] == 46 && name[2] == 0) { return }
                visit(name, parent: parent)
            }
        }
    }

    private func openRoot(_ root: URL) {
        guard root.isFileURL, let mounts else { skipped = true; return }
        var remote = false
        guard let resolved = mounts.localRoot(root.path(percentEncoded: false), excludedVolume: &remote) else {
            skippedNetwork = skippedNetwork || remote
            skipped = true
            return
        }
        resolved.withCString { path in
            var metadata = stat()
            guard lstat(path, &metadata) == 0 else {
                if !(apps && errno == ENOENT) { skipped = true }
                return
            }
            let base = URL(fileURLWithFileSystemRepresentation: path, isDirectory: true, relativeTo: nil)
            guard metadata.st_mode & S_IFMT == S_IFDIR,
                  let cursor = DirectoryCursor(path, relativeTo: AT_FDCWD, expected: metadata,
                                               role: .discovery, discoveryURL: base, mountBranch: mounts.branch(resolved)) else { skipped = true; return }
            stack.append(cursor)
        }
    }

    private func visit(_ name: UnsafePointer<CChar>, parent: DirectoryCursor) {
        var childBranch: String?
        if let branch = parent.mountBranch, let mounts {
            let path = Self.join(branch, String(cString: name))
            // APFS firmlinks can give two distinct mounted volumes the same st_dev.
            // Their mounted names are boundaries even when the device number matches.
            if mounts.isMount(path) {
                skippedNetwork = skippedNetwork || mounts.isRemoteMount(path)
                markSkipped()
                return
            }
            childBranch = mounts.branch(path)
        }
        let fd = dirfd(parent.stream)
        var metadata = stat()
        guard fstatat(fd, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              metadata.st_dev == parent.volume else { markSkipped(); return }
        let kind = metadata.st_mode & S_IFMT
        if kind != S_IFDIR, metadata.st_flags & UInt32(SF_DATALESS) != 0 { markSkipped() }
        var role = DirectoryCursor.Role.descendant
        var discoveryURL: URL?
        if let base = parent.discoveryURL {
            guard kind == S_IFDIR else {
                if !apps, kind == S_IFREG {
                    directBytes += Self.allocation(metadata, links: &directLinks, partial: &skipped)
                    totalBytes += Self.allocation(metadata, links: &totalLinks, partial: &skipped)
                }
                return
            }
            let url = URL(fileURLWithFileSystemRepresentation: name, isDirectory: true, relativeTo: base).absoluteURL
            if apps, url.pathExtension.caseInsensitiveCompare("app") != .orderedSame {
                role = .discovery
                discoveryURL = url
            } else {
                if apps {
                    let id = FileID(metadata)
                    guard !appIDs.contains(id) else { return }
                    guard appIDs.count < Self.maxIDs else { skipped = true; return }
                    appIDs.insert(id)
                }
                role = .itemRoot
                currentURL = url
                currentBytes = 0
                currentPartial = false
                currentLinks.removeAll(keepingCapacity: true)
            }
        }
        if role != .discovery {
            currentBytes += Self.allocation(metadata, links: &currentLinks, partial: &currentPartial)
            totalBytes += Self.allocation(metadata, links: &totalLinks, partial: &skipped)
        }
        guard kind == S_IFDIR else { return }
        guard stack.count < Self.maxDepth,
              let cursor = DirectoryCursor(name, relativeTo: fd, expected: metadata, role: role,
                                           discoveryURL: discoveryURL, mountBranch: childBranch) else {
            markSkipped()
            if role == .itemRoot { finishItem() }
            return
        }
        stack.append(cursor)
    }

    private func markSkipped() {
        if currentURL != nil { currentPartial = true }
        else { skipped = true }
    }

    // Track links per ranked item so its size is independent of traversal order.
    private static func allocation(_ metadata: stat, links: inout Set<FileID>, partial: inout Bool) -> UInt64 {
        if metadata.st_nlink > 1, metadata.st_mode & S_IFMT != S_IFDIR {
            let id = FileID(metadata)
            if links.contains(id) { return 0 }
            guard links.count < maxIDs else { partial = true; return 0 }
            links.insert(id)
        }
        return UInt64(max(0, metadata.st_blocks)) * 512
    }

    private static func precedes(_ a: StorageEntry, _ b: StorageEntry) -> Bool {
        if a.bytes != b.bytes { return a.bytes > b.bytes }
        let order = a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent)
        return order == .orderedSame ? a.url.path < b.url.path : order == .orderedAscending
    }

    private func finishItem() {
        guard let url = currentURL else { return }
        let row = StorageEntry(url: url, bytes: currentBytes, isPartial: currentPartial, isScanning: false)
        itemCount += 1
        skipped = skipped || currentPartial
        if ranked.count < Self.maxRanked {
            ranked.append(row)
            if Self.precedes(ranked[worstRank], row) { worstRank = ranked.count - 1 }
        } else if Self.precedes(row, ranked[worstRank]) {
            ranked[worstRank] = row
            worstRank = ranked.indices.max(by: { Self.precedes(ranked[$0], ranked[$1]) }) ?? 0
        }
        currentURL = nil
        currentBytes = 0
        currentPartial = false
    }

    func snapshot(terminal: Bool, limited: Bool) -> InventoryUpdate {
        var rows = ranked
        if let url = currentURL {
            rows.append(StorageEntry(url: url, bytes: currentBytes,
                                     isPartial: currentPartial || limited, isScanning: !terminal))
        }
        rows.sort(by: Self.precedes)
        if rows.count > Self.maxRanked { rows.removeLast() }
        return InventoryUpdate(entries: rows, isComplete: terminal, hasSkippedItems: skipped || currentPartial,
                               directFileBytes: apps ? nil : directBytes, reachedScanLimit: limited, skippedNetworkVolume: skippedNetwork,
                               measuredItemCount: itemCount + (currentURL == nil ? 0 : 1),
                               measuredBytes: totalBytes)
    }
}
