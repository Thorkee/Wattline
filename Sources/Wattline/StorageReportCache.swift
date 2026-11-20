import Darwin
import Foundation

typealias DatedStorageReport = (update: InventoryUpdate, date: Date)

protocol StorageReportCaching: Sendable {
    func load() async -> DatedStorageReport?
    func save(_ update: InventoryUpdate, at date: Date)
}

/// A single, replaceable snapshot of the Applications ranking.
struct StorageReportCache: StorageReportCaching {
    private let location: URL?

    static let standard = Self(location: nil)

    init(fileURL: URL) { location = fileURL }
    private init(location: URL?) { self.location = location }

    var fileURL: URL {
        location ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.wattline.macos/apps-v1.json", isDirectory: false)
    }

    private static let queue = DispatchQueue(label: "local.wattline.storage-report-cache", qos: .utility)
    private static let maximumBytes = 256 * 1024
    private static let maximumRows = 256
    private static let roots = [
        "/Applications/", "/System/Applications/",
        FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/"
    ]

    private struct Row: Codable {
        let path: String
        let bytes: UInt64
        let isPartial: Bool
    }

    private struct Report: Codable {
        let version: Int
        let date: Date
        let rows: [Row]
        let count: Int
        let bytes: UInt64
        let skipped: Bool
        let limited: Bool
        let skippedNetworkVolume: Bool?

        var valid: Bool {
            guard version == 1, date.timeIntervalSince1970.isFinite,
                  rows.count <= StorageReportCache.maximumRows, count >= rows.count,
                  !rows.isEmpty || count == 0,
                  count != 0 || bytes == 0, bytes <= UInt64(Int64.max) else { return false }
            var seen = Set<String>()
            var subtotal: UInt64 = 0
            for row in rows {
                let path = row.path
                guard StorageReportCache.roots.contains(where: { path.hasPrefix($0) }),
                      path.lowercased().hasSuffix(".app"), path.utf8.count <= 4096,
                      !path.contains("\0"), !path.contains("//"),
                      !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
                      seen.insert(path).inserted, row.bytes <= UInt64(Int64.max),
                      skipped || row.bytes <= bytes else { return false }
                let (sum, overflow) = subtotal.addingReportingOverflow(row.bytes)
                guard !overflow else { return false }
                subtotal = sum
            }
            // An allocation shared by two app bundles contributes to each row,
            // while the overall total includes that hard link once.
            return count > rows.count || bytes <= subtotal
        }
    }

    func load() async -> DatedStorageReport? {
        await withCheckedContinuation { continuation in
            Self.queue.async { continuation.resume(returning: self.readReport()) }
        }
    }

    private func readReport() -> DatedStorageReport? {
        let fd = fileURL.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              (1...Int64(Self.maximumBytes)).contains(info.st_size),
              let data = try? handle.read(upToCount: Self.maximumBytes + 1),
              data.count == Int(info.st_size),
              let report = try? JSONDecoder().decode(Report.self, from: data), report.valid else { return nil }
        let entries = report.rows.map {
            StorageEntry(url: URL(fileURLWithPath: $0.path, isDirectory: true),
                         bytes: $0.bytes, isPartial: $0.isPartial, isScanning: false)
        }
        var update = InventoryUpdate(entries: entries, isComplete: true, hasSkippedItems: report.skipped)
        update.reachedScanLimit = report.limited
        update.skippedNetworkVolume = report.skippedNetworkVolume ?? false
        update.measuredItemCount = report.count
        update.measuredBytes = report.bytes
        return (update, report.date)
    }

    func save(_ update: InventoryUpdate, at date: Date) {
        guard update.isComplete, update.directFileBytes == nil else { return }
        Self.queue.async {
            var total: UInt64 = 0
            if let bytes = update.measuredBytes {
                total = bytes
            } else {
                for entry in update.entries {
                    let (sum, overflow) = total.addingReportingOverflow(entry.bytes)
                    guard !overflow else { return }
                    total = sum
                }
            }
            let rows = update.entries.prefix(Self.maximumRows).map { entry in
                let path = entry.url.path(percentEncoded: false)
                return Row(path: path.hasSuffix("/") ? String(path.dropLast()) : path,
                           bytes: entry.bytes, isPartial: entry.isPartial || entry.isScanning)
            }
            let report = Report(version: 1, date: date, rows: rows, count: update.measuredItemCount ?? update.entries.count,
                                bytes: total, skipped: update.hasSkippedItems, limited: update.reachedScanLimit,
                                skippedNetworkVolume: update.skippedNetworkVolume)
            guard report.valid, let data = try? JSONEncoder().encode(report), data.count <= Self.maximumBytes else { return }
            let destination = self.fileURL
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
            } catch {
                // The current in-memory report remains usable when caches cannot be written.
            }
        }
    }
}
