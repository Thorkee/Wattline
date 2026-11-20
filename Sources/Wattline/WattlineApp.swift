import AppKit
import Combine
import SwiftUI

@main
@MainActor
enum WattlineApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
private final class PowerDropdownPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class MonitorVisibility: ObservableObject {
    @Published fileprivate(set) var isSampling = false
    @Published fileprivate(set) var canScanStorage = false
}

@MainActor
final class WattlineNavigation: ObservableObject {
    @Published var showsSettings = false
    @Published var shortcutAvailable = false
}

@MainActor
private final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let visibility = MonitorVisibility()
    private(set) var isOpen = false
    private var systemAsleep = false
    private var displaysAsleep = false

    init(power: PowerMonitor, navigation: WattlineNavigation, screen: NSScreen) {
        let size = NSSize(width: 940, height: 650)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: true, screen: screen)
        super.init(window: window)
        let controller = NSHostingController(rootView: SystemMonitorView(power: power, visibility: visibility, navigation: navigation))
        controller.sizingOptions = []
        window.contentViewController = controller
        window.title = "Wattline"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenPrimary, .moveToActiveSpace]
        window.setContentSize(size)
        window.setFrame(WindowPlacement.frame(size: window.frame.size, in: screen.visibleFrame, anchor: .center),
                        display: false)
        window.setFrameAutosaveName("WattlineMonitor")

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            workspace.addObserver(self, selector: #selector(workspaceChanged), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(on screen: NSScreen) {
        guard let window else { return }
        isOpen = true
        if window.isMiniaturized { window.deminiaturize(nil) }
        fit(on: screen)
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        updateVisibility()
    }

    func fit(on screen: NSScreen) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let area = screen.visibleFrame
        let available = window.contentRect(forFrameRect: area).size
        window.contentMinSize = NSSize(width: min(560, available.width), height: min(420, available.height))
        if !area.contains(window.frame) {
            let target = WindowPlacement.frame(size: window.frame.size, in: area, anchor: .center)
            window.setFrame(target, display: window.isVisible)
        }
    }

    @objc private func workspaceChanged(_ notification: Notification) {
        switch notification.name {
        case NSWorkspace.willSleepNotification: systemAsleep = true
        case NSWorkspace.didWakeNotification: systemAsleep = false
        case NSWorkspace.screensDidSleepNotification: displaysAsleep = true
        case NSWorkspace.screensDidWakeNotification: displaysAsleep = false
        default: return
        }
        updateVisibility()
    }

    func updateVisibility() {
        guard let window else { return }
        let open = isOpen && !systemAsleep && !displaysAsleep && !NSApp.isHidden
            && window.isVisible && !window.isMiniaturized
        if visibility.canScanStorage != open { visibility.canScanStorage = open }
        let visible = open && window.occlusionState.contains(.visible)
        if visibility.isSampling != visible { visibility.isSampling = visible }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { updateVisibility() }
    func windowDidMiniaturize(_ notification: Notification) { updateVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { updateVisibility() }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        updateVisibility()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let monitor = PowerMonitor()
    private let navigation = WattlineNavigation()
    private var item: NSStatusItem?
    private var observation: AnyCancellable?
    private var preferencesObservation: AnyCancellable?
    private var shortcut: PanelShortcut?
    private var dropdown: PowerDropdownPanel?
    private var dropdownAnchor: WindowPlacement.Anchor = .topTrailing
    private var sourceButtonFrame: CGRect?
    private var outsideClickMonitors: [Any] = []
    private var dropdownScreenID: NSNumber?
    private var dropdownSizeObservation: NSKeyValueObservation?
    private var shortcutAvailability: AnyCancellable?
    private var mainWindowController: MainWindowController?
    private var currentAppearance: String?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            return menu
        }

        let app = submenu("Wattline")
        app.addItem(withTitle: "About Wattline", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "").target = NSApp
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Wattline", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h").target = NSApp
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "").target = NSApp
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Wattline", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp

        let edit = submenu("Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let window = submenu("Window")
        window.addItem(withTitle: "Show Wattline", action: #selector(openMainWindow), keyEquivalent: "0").target = self
        window.addItem(.separator())
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "").target = NSApp
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activeSpaceChanged),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        monitor.health.onOpenDetails = { [weak self] in self?.openSettings() }
        monitor.health.configure()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item
        item.autosaveName = "WattlinePower"
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(statusItemPressed)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        shortcut = PanelShortcut { [weak self] in self?.toggleFromKeyboard() }
        shortcutAvailability = shortcut?.$isAvailable.removeDuplicates().sink { [weak self] available in
            self?.navigation.shortcutAvailable = available
        }
        observation = monitor.$latest.sink { [weak self] reading in self?.updateButton(reading) }
        preferencesObservation = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateButton(self.monitor.latest)
                self.applyAppearance()
                self.monitor.health.applyPreferences()
            }
        monitor.start()
        openMainWindow()
    }

    private func screenID(_ screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    @objc private func activeSpaceChanged() {
        dropdown?.close()
    }

    private func applyAppearance() {
        let choice = UserDefaults.standard.string(forKey: WattlinePreferences.appearanceKey) ?? "system"
        guard currentAppearance != choice else { return }
        currentAppearance = choice
        switch choice {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        monitor.health.refreshAuthorization()
    }

    private func makePanel() -> PowerPanel {
        PowerPanel(monitor: monitor, onOpenWattline: { [weak self] in self?.openMainWindow() },
                   onSettings: { [weak self] in self?.openSettings() },
                   onQuit: { NSApp.terminate(nil) })
    }

    @objc private func openMainWindow() {
        let screen = dropdown?.screen
        presentMainWindow(on: screen ?? mainWindowController?.window?.screen ?? pointerScreen)
    }

    private func presentMainWindow(on screen: NSScreen?) {
        guard let screen else { return }
        dropdown?.close()
        if mainWindowController == nil {
            mainWindowController = MainWindowController(power: monitor, navigation: navigation, screen: screen)
        }
        mainWindowController?.present(on: screen)
    }

    @objc private func openSettings() {
        shortcut?.refresh()
        navigation.showsSettings = true
        openMainWindow()
    }

    private var pointerScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    private func updateButton(_ reading: PowerReading) {
        let showsWatts = UserDefaults.standard.bool(forKey: "showMenuWatts")
        guard let button = item?.button else { return }
        button.image = MenuBarMark(state: reading.state, percent: reading.percent).image
        let watts = WattageFormat.menuDraw(reading.systemWatts)
        button.imagePosition = showsWatts ? .imageLeading : .imageOnly
        button.title = showsWatts ? " " + (watts ?? "—") : ""
        let length = showsWatts ? NSStatusItem.variableLength : NSStatusItem.squareLength
        if item?.length != length { item?.length = length }
        let percent = reading.percent.map { " · " + (Double($0) / 100).formatted(.percent) + " battery" } ?? ""
        let draw = watts.map { $0 + " Mac power draw" } ?? "Mac power draw unavailable"
        let description = "Wattline · \(draw) · \(reading.state.title)\(percent)"
        button.toolTip = description + "\nClick for quick power details."
        button.setAccessibilityLabel(description)
        button.setAccessibilityHelp("Show or hide quick power details.")
    }

    // A status item can be mirrored in several menu bars while AppKit supplies
    // just one button window. Resolve the physical click before opening a window.
    @objc private func statusItemPressed() {
        guard let button = item?.button else { return }
        let proxy = button.window?.convertToScreen(button.convert(button.bounds, to: nil))
        let pointer = NSEvent.mouseLocation
        let event = NSApp.currentEvent
        let eventPoint: CGPoint?
        switch event?.type {
        case .leftMouseUp, .rightMouseUp: eventPoint = event?.cgEvent?.unflippedLocation
        default: eventPoint = nil
        }

        let proxyCenter = proxy.map { CGPoint(x: $0.midX, y: $0.midY) }
        var location: (NSScreen, CGPoint)?
        for point in [pointer, eventPoint, proxyCenter].compactMap({ $0 }) {
            if let screen = NSScreen.screens.first(where: { screen in
                let strip = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness, button.bounds.height)
                return screen.frame.contains(point) && point.y >= screen.frame.maxY - strip - 1
            }) {
                location = (screen, point)
                break
            }
        }
        guard let screen = location?.0 ?? pointerScreen else { return }
        let point = location?.1 ?? CGPoint(x: screen.visibleFrame.maxX - button.bounds.width / 2, y: screen.frame.maxY)
        let anchorX = proxy.flatMap { $0.contains(point) ? $0.midX : nil } ?? point.x
        let strip = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness, button.bounds.height)
        let hitArea = CGRect(x: anchorX - button.bounds.width / 2, y: screen.frame.maxY - strip,
                             width: button.bounds.width, height: strip)
        if let panel = dropdown {
            let sameDisplay = dropdownScreenID == screenID(screen)
            panel.close()
            if sameDisplay { return }
        }
        showDropdown(on: screen, anchor: .menuItem(x: anchorX), sourceFrame: hitArea)
    }

    private func toggleFromKeyboard() {
        if let panel = dropdown { panel.close(); return }
        if let screen = pointerScreen { showDropdown(on: screen, anchor: .topTrailing, sourceFrame: nil) }
    }

    private func showDropdown(on screen: NSScreen, anchor: WindowPlacement.Anchor, sourceFrame: CGRect?) {
        let controller = NSHostingController(rootView: makePanel().clipShape(RoundedRectangle(cornerRadius: 14)))
        let size = controller.view.fittingSize
        controller.sizingOptions = [.preferredContentSize]
        let panel = PowerDropdownPanel(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .transient, .ignoresCycle]
        panel.contentViewController = controller
        panel.delegate = self
        dropdown = panel
        dropdownAnchor = anchor
        sourceButtonFrame = sourceFrame
        panel.title = "Wattline power details"
        panel.isExcludedFromWindowsMenu = true
        dropdownScreenID = screenID(screen)
        placeDropdown(panel, size: size, screen: screen)
        dropdownSizeObservation = controller.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateDropdownPlacement() }
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        item?.button?.highlight(sourceFrame != nil)
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let token = NSEvent.addGlobalMonitorForEvents(matching: mouseDown, handler: { [weak self] _ in
            self?.dismissIfOutside()
        }) { outsideClickMonitors.append(token) }
        if let token = NSEvent.addLocalMonitorForEvents(matching: mouseDown, handler: { [weak self] event in
            self?.dismissIfOutside()
            return event
        }) { outsideClickMonitors.append(token) }
        monitor.setPanelVisible(true)
    }

    private func dismissIfOutside() {
        let point = NSEvent.mouseLocation
        if let panel = dropdown, !panel.frame.contains(point), sourceButtonFrame?.contains(point) != true {
            panel.close()
        }
    }

    private func placeDropdown(_ panel: NSPanel, size: CGSize, screen: NSScreen) {
        guard size.width > 0, size.height > 0 else { return }
        let frame = screen.frame
        let insets = screen.safeAreaInsets
        let safe = CGRect(x: frame.minX + insets.left, y: frame.minY + insets.bottom,
                          width: frame.width - insets.left - insets.right,
                          height: frame.height - insets.top - insets.bottom)
        var area = screen.visibleFrame.intersection(safe)
        if case .menuItem = dropdownAnchor {
            let barBottom = frame.maxY - max(insets.top, NSStatusBar.system.thickness, item?.button?.bounds.height ?? 0)
            area.size.height = max(0, min(area.maxY, barBottom) - area.minY)
        }
        guard !area.isEmpty else { return }
        let target = WindowPlacement.frame(size: size, in: area, anchor: dropdownAnchor)
        if panel.frame != target { panel.setFrame(target, display: false) }
    }

    private func updateDropdownPlacement() {
        guard let panel = dropdown, let controller = panel.contentViewController else { return }
        let previous = NSScreen.screens.first {
            screenID($0) == dropdownScreenID
        }
        guard let screen = previous else { panel.close(); return }
        placeDropdown(panel, size: controller.view.fittingSize, screen: screen)
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        updateDropdownPlacement()
        if let controller = mainWindowController, controller.isOpen, let screen = controller.window?.screen ?? pointerScreen {
            controller.fit(on: screen)
        }
    }

    func applicationDidHide(_ notification: Notification) { mainWindowController?.updateVisibility() }
    func applicationDidUnhide(_ notification: Notification) { mainWindowController?.updateVisibility() }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === dropdown else { return }
        outsideClickMonitors.forEach(NSEvent.removeMonitor)
        outsideClickMonitors.removeAll()
        sourceButtonFrame = nil
        item?.button?.highlight(false)
        dropdownSizeObservation = nil
        dropdownScreenID = nil
        dropdown = nil
        monitor.setPanelVisible(false)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let panel = notification.object as? PowerDropdownPanel else { return }
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.dropdown === panel, !panel.isKeyWindow else { return }
            if self.sourceButtonFrame?.contains(NSEvent.mouseLocation) != true { panel.close() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        monitor.stop()
        observation?.cancel()
        preferencesObservation?.cancel()
        shortcutAvailability?.cancel()
        shortcut = nil
    }
}
