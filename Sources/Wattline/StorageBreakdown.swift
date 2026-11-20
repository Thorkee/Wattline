import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class StorageBreakdownModel: ObservableObject {
    enum Phase: Equatable { case idle, scanning, stopped, complete(Date) }

    @Published private(set) var scope = InventoryScope.apps
    @Published private(set) var update: InventoryUpdate?
    @Published private(set) var phase = Phase.idle
    private(set) var folders = [FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL]

    private struct Snapshot {
        let update: InventoryUpdate?
        let phase: Phase
        let saved: Date
    }

    private let scanOverride: ((InventoryScope) -> AsyncStream<InventoryUpdate>)?
    private let appCache: (any StorageReportCaching)?
    private var cacheRead: Task<Void, Never>?
    private var checkedAppCache = false
    private var appsGeneration = 0
    private var snapshots: [InventoryScope: Snapshot] = [:]
    private var session: StorageInventorySession?
    private var checkpoints: [InventoryScope: StorageInventorySession] = [:]
    private var expirations: [InventoryScope: Task<Void, Never>] = [:]
    private var checkpointOrder: [InventoryScope] = []
    private var task: Task<Void, Never>?
    private var generation = 0
    private var active = false
    private var automatic: Bool

    init(scan: ((InventoryScope) -> AsyncStream<InventoryUpdate>)? = nil, cache: (any StorageReportCaching)? = nil) {
        scanOverride = scan
        automatic = scan != nil
        appCache = cache
    }

    convenience init() { self.init(cache: StorageReportCache.standard) }

    var canContinue: Bool { update?.reachedScanLimit == true && checkpoints[scope] != nil }

    func setActive(_ newValue: Bool) {
        guard active != newValue else { return }
        active = newValue
        if newValue {
            if phase == .idle { showScope() }
        } else {
            stop()
        }
    }

    func setAutomaticScanning(_ enabled: Bool) {
        guard automatic != enabled else { return }
        automatic = enabled
        if enabled && active && phase == .idle { showScope() }
    }

    func selectApps() { select(.apps) }
    func selectFolders() {
        guard let url = folders.last else { return }
        select(.folder(url))
    }

    func enter(_ folder: URL, asRoot: Bool = false) {
        let url = folder.standardizedFileURL
        if asRoot { folders = [url] }
        else if let index = folders.firstIndex(of: url) { folders = Array(folders[...index]) }
        else { folders.append(url) }
        select(.folder(url))
    }

    func back() {
        guard folders.count > 1 else { return }
        folders.removeLast()
        selectFolders()
    }

    private func select(_ newScope: InventoryScope) {
        guard newScope != scope else { return }
        stop()
        scope = newScope
        showScope()
    }

    private func showScope() {
        if let last = snapshots[scope] {
            update = last.update
            phase = last.phase
            return
        }
        phase = .idle
        update = nil
        guard active else { return }
        if scope == .apps, let appCache, !checkedAppCache {
            guard cacheRead == nil else { return }
            let token = appsGeneration
            cacheRead = Task { [weak self] in
                let report = await appCache.load()
                guard let self, !Task.isCancelled, self.appsGeneration == token else { return }
                self.cacheRead = nil
                self.checkedAppCache = true
                if let report {
                    self.remember(.apps, update: report.update, phase: .complete(report.date))
                }
                if self.active, self.scope == .apps, self.phase == .idle { self.showScope() }
            }
        } else if automatic {
            measure()
        }
    }

    private func remember() {
        remember(scope, update: update, phase: phase)
    }

    private func remember(_ key: InventoryScope, update: InventoryUpdate?, phase: Phase) {
        snapshots[key] = Snapshot(update: update, phase: phase, saved: Date())
        if snapshots.count > 12, let oldest = snapshots.min(by: { $0.value.saved < $1.value.saved })?.key {
            snapshots.removeValue(forKey: oldest)
            removeCheckpoint(oldest)?.cancel()
        }
    }

    private func removeCheckpoint(_ key: InventoryScope) -> StorageInventorySession? {
        expirations.removeValue(forKey: key)?.cancel()
        checkpointOrder.removeAll { $0 == key }
        return checkpoints.removeValue(forKey: key)
    }

    func stop() {
        guard phase == .scanning else { return }
        generation += 1
        session?.cancel()
        session = nil
        task?.cancel()
        task = nil
        phase = .stopped
        remember()
    }

    func measure() {
        guard active, phase != .scanning else { return }
        if scope == .apps {
            appsGeneration += 1
            checkedAppCache = true
            cacheRead?.cancel()
            cacheRead = nil
        }
        removeCheckpoint(scope)?.cancel()
        update = nil
        if let scanOverride {
            consume(scanOverride(scope))
        } else {
            let fresh = StorageInventorySession(scope)
            session = fresh
            consume(fresh.nextBatch())
        }
    }

    func continueScan() {
        guard active, phase != .scanning, let paused = removeCheckpoint(scope) else { return }
        session = paused
        consume(paused.nextBatch())
    }

    private func consume(_ stream: AsyncStream<InventoryUpdate>) {
        generation += 1
        let token = generation
        phase = .scanning
        task = Task { [weak self] in
            for await result in stream {
                guard let self, self.generation == token, !Task.isCancelled else { break }
                self.update = result
                if result.isComplete {
                    let date = Date()
                    if result.reachedScanLimit, let paused = self.session {
                        self.checkpoints[self.scope] = paused
                        self.checkpointOrder.append(self.scope)
                        let key = self.scope
                        self.expirations[key] = Task { [weak self] in
                            do { try await Task.sleep(for: .seconds(180)) } catch { return }
                            guard let self else { return }
                            self.objectWillChange.send()
                            self.removeCheckpoint(key)?.cancel()
                        }
                        if self.checkpointOrder.count > 2, let oldest = self.checkpointOrder.first {
                            self.removeCheckpoint(oldest)?.cancel()
                        }
                    }
                    self.session = nil
                    self.phase = .complete(date)
                    self.remember()
                    if self.scope == .apps { self.appCache?.save(result, at: date) }
                    break
                }
            }
            guard let self, self.generation == token else { return }
            if self.phase == .scanning {
                self.phase = .stopped
                self.remember()
            }
            self.task = nil
        }
    }

}

struct StorageBreakdown: View {
    @ObservedObject var model: StorageBreakdownModel
    let active: Bool
    @AppStorage(WattlinePreferences.automaticStorageKey) private var automaticScanning = false
    @State private var visibleCount = 10
    @State private var showsDetails = false

    private var apps: Bool { model.scope == .apps }
    private var entries: [StorageEntry] { model.update?.entries ?? [] }
    private var tint: Color { WattlineStyle.marine }
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL }
    private var scopePath: String {
        guard case .folder(let folder) = model.scope else { return "" }
        let path = folder.path(percentEncoded: false)
        if folder.standardizedFileURL.path == home.path { return "Home" }
        if path.hasPrefix(home.path + "/") { return "~" + path.dropFirst(home.path.count) }
        return path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Picker("Rank by", selection: Binding(get: { apps }, set: { $0 ? model.selectApps() : model.selectFolders() })) {
                    Text("Apps").tag(true)
                    Text("Folders").tag(false)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
                Spacer(minLength: 2)
                Button("Choose folder…", action: chooseFolder)
                    .controlSize(.small)
                if model.phase == .scanning {
                    ProgressView().controlSize(.small).accessibilityLabel("Scanning disk usage")
                    Button("Stop") { model.stop() }
                        .controlSize(.small).accessibilityLabel("Stop storage scan")
                } else if model.phase == .idle {
                    Button(apps ? "Scan apps" : "Scan folders") { model.measure() }
                        .controlSize(.small)
                } else if model.canContinue {
                    Button("Continue") { model.continueScan() }
                        .controlSize(.small).accessibilityLabel("Continue storage scan")
                        .help("Measure another part of this location")
                } else {
                    Button { model.measure() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).accessibilityLabel("Rescan storage").help("Rescan storage")
                }
            }
            .frame(minHeight: 28)
            if case .folder = model.scope {
                HStack(spacing: 6) {
                    if model.folders.count > 1 {
                        Button { model.back() } label: { Image(systemName: "chevron.left") }
                            .buttonStyle(.borderless).accessibilityLabel("Back to parent folder")
                    }
                    Image(systemName: "folder").foregroundStyle(tint).accessibilityHidden(true)
                    Text(scopePath).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        .help(scopePath)
                    Spacer(minLength: 2)
                    if model.folders.first?.standardizedFileURL != home {
                        Button("Home") { model.enter(home, asRoot: true) }
                            .buttonStyle(.borderless)
                            .help("Show the largest folders in your home folder")
                    }
                }
                .padding(.top, 8)
            }
            HStack(alignment: .center, spacing: 8) {
                Text(apps ? "Largest apps" : "Largest folders")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Button { showsDetails.toggle() } label: {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About storage sizes").help("About storage sizes")
                .popover(isPresented: $showsDetails) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Size on disk").font(.headline)
                        Text(apps
                             ? "Apps shows installed application bundles. Their documents, caches, and other support files appear under Folders."
                             : "Each row measures one immediate subfolder, including hidden items. Files stored directly in this folder are counted separately.")
                        Text("Large locations are measured in short passes. Select Continue to measure more.")
                        Text("Sizes reflect locally allocated space. Shared APFS blocks can affect the space you recover by removing an item.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout).frame(width: 248, alignment: .leading).padding(14)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 4)
            Text(status)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let count = model.update?.measuredItemCount, count > entries.count {
                Text("Showing the largest \(entries.count) measured items.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 3)
            }
            if !apps, let direct = model.update?.directFileBytes, direct > 0 {
                Text(diskSize(direct) + " in files directly in this folder")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 3)
            }
            if model.update?.hasSkippedItems == true {
                Label(model.update?.skippedNetworkVolume == true
                      ? "Network volumes are excluded. Partial sizes show ≥."
                      : "Some items were skipped. Partial sizes show ≥.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

            Divider().padding(.top, 12)
            if entries.isEmpty {
                Text(emptyLabel)
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries.prefix(visibleCount)) { entry in
                        StorageRankRow(entry: entry, largest: entries.first?.bytes ?? 0,
                                       apps: apps, stopped: model.phase == .stopped, openFolder: { model.enter(entry.url) })
                    }
                    if entries.count > visibleCount {
                        Button("Show more (\(entries.count - visibleCount) remaining)") { visibleCount += 20 }
                            .buttonStyle(.borderless).font(.callout)
                            .padding(.top, 8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            model.setAutomaticScanning(automaticScanning)
            model.setActive(active)
        }
        .onChange(of: automaticScanning) { _, value in model.setAutomaticScanning(value) }
        .onChange(of: active) { _, value in model.setActive(value) }
        .onDisappear { model.setActive(false) }
        .onChange(of: model.scope) { _, _ in visibleCount = 10 }
    }

    private var totalLabel: String {
        guard let update = model.update else { return "—" }
        let total = update.measuredBytes ?? entries.reduce(update.directFileBytes ?? 0) { sum, entry in
            let (bytes, overflow) = sum.addingReportingOverflow(entry.bytes)
            return overflow ? .max : bytes
        }
        let partial = model.phase == .scanning || model.phase == .stopped || update.hasSkippedItems || update.reachedScanLimit
        if partial && total == 0 { return "—" }
        return (partial ? "≥ " : "") + diskSize(total)
    }

    private var status: String {
        let count = model.update?.measuredItemCount ?? entries.count
        let unit = apps ? (count == 1 ? "app bundle" : "app bundles") : (count == 1 ? "subfolder" : "subfolders")
        switch model.phase {
        case .scanning: return count == 0 ? "Looking for \(apps ? "applications" : "folders")…" : "Scanning · \(count) \(unit) · \(totalLabel)"
        case .complete(let date):
            let stamp = DateFormatter.localizedString(from: date, dateStyle: Calendar.current.isDateInToday(date) ? .none : .short, timeStyle: .short)
            if model.update?.reachedScanLimit == true { return "Partial scan · \(count) \(unit) · \(totalLabel) · \(stamp)" }
            return "\(count) \(unit) · \(totalLabel) measured · Updated " + stamp
        case .stopped: return count == 0 ? "Scan stopped" : "Scan stopped · \(count) \(unit) · \(totalLabel)"
        case .idle: return apps ? "Installed application bundles" : "Immediate subfolders"
        }
    }

    private var emptyLabel: String {
        if model.update?.reachedScanLimit == true {
            return model.canContinue ? "Continue scanning to look for more items." : "Rescan this location to look for more items."
        }
        if model.update?.skippedNetworkVolume == true { return "Choose a local folder to measure its contents." }
        if model.update?.hasSkippedItems == true { return "No readable items found." }
        switch model.phase {
        case .complete: return apps ? "No applications found." : "This folder has no subfolders."
        case .scanning: return "Results appear as items are measured."
        case .stopped: return "Rescan to measure this location."
        case .idle: return apps ? "Select Scan apps to rank installed applications by size." : "Select Scan folders to measure the subfolders here."
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan Folder"
        if case .folder(let url) = model.scope { panel.directoryURL = url }
        let handle: (NSApplication.ModalResponse) -> Void = { result in
            if result == .OK, let url = panel.url {
                model.enter(url, asRoot: true)
                if model.phase == .idle || model.phase == .stopped { model.measure() }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: handle) }
        else { panel.begin(completionHandler: handle) }
    }
}

private func diskSize(_ bytes: UInt64) -> String {
    bytes == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .decimal)
}

private struct StorageRankRow: View {
    let entry: StorageEntry
    let largest: UInt64
    let apps: Bool
    let stopped: Bool
    let openFolder: () -> Void
    @State private var hovered = false
    @State private var icon: NSImage?
    @State private var displayName: String?
    @Environment(\.colorSchemeContrast) private var contrast

    private var name: String {
        displayName ?? (apps ? entry.url.deletingPathExtension().lastPathComponent : entry.url.lastPathComponent)
    }
    private var value: String {
        if entry.isScanning && entry.bytes == 0 { return stopped ? "—" : "Measuring…" }
        if entry.isPartial && entry.bytes == 0 { return "—" }
        return (entry.isPartial || entry.isScanning ? "≥ " : "") + diskSize(entry.bytes)
    }

    var body: some View {
        HStack(spacing: 9) {
            if apps { rowContent }
            else {
                Button(action: openFolder) { rowContent }
                    .buttonStyle(.plain).accessibilityLabel("Open \(name), \(value)")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.body).frame(width: 25, height: 28)
                    .foregroundStyle(hovered ? Color.primary : .secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reveal \(name) in Finder").help("Reveal in Finder")
        }
        .padding(.vertical, 5)
        .background { if hovered { RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(0.035)) } }
        .onHover { hovered = $0 }
        .contextMenu {
            if !apps { Button("Open folder", action: openFolder) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        }
        .task(id: entry.isPartial || entry.isScanning) {
            guard apps else {
                icon = NSWorkspace.shared.icon(for: .folder)
                return
            }
            guard !entry.isPartial && !entry.isScanning else {
                icon = NSWorkspace.shared.icon(for: .applicationBundle)
                return
            }
            if let title = Bundle(url: entry.url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                displayName = title
            }
            icon = NSWorkspace.shared.icon(forFile: entry.url.path(percentEncoded: false))
        }
    }

    private var rowContent: some View {
        HStack(spacing: 9) {
            Group {
                if let icon { Image(nsImage: icon).resizable().interpolation(.high).scaledToFit() }
                else { Image(systemName: apps ? "app" : "folder").foregroundStyle(WattlineStyle.marine) }
            }
            .accessibilityHidden(true)
            .frame(width: 29, height: 29)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if !apps {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                    Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                GeometryReader { geometry in
                    let fraction = largest == 0 ? 0 : min(Double(entry.bytes) / Double(largest), 1)
                    ZStack(alignment: .leading) {
                        Capsule().fill(.secondary.opacity(contrast == .increased ? 0.24 : 0.10))
                        Capsule().fill(WattlineStyle.marine.opacity(contrast == .increased ? 1 : 0.78))
                            .frame(width: geometry.size.width * fraction)
                    }
                }
                .frame(height: 3)
                .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .help(entry.url.path(percentEncoded: false))
        .accessibilityElement(children: .combine)
    }
}
