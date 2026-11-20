import AppKit
import Combine
import UserNotifications

/// Contains only the stable IDs of issues in the current health report.
struct HealthAlertDelivery {
    enum Access { case checking, allowed, blocked }

    private var pending: Set<String> = []
    private var sent: Set<String> = []

    mutating func reconcile(active: [HealthIssue], newAlerts: [HealthIssue], access: Access) -> [HealthIssue] {
        guard !newAlerts.isEmpty || !pending.isEmpty || !sent.isEmpty else { return [] }
        let current = Set(active.map(\.id))
        pending.formIntersection(current)
        sent.formIntersection(current)
        guard access != .blocked else {
            pending.removeAll()
            return []
        }
        for issue in newAlerts where current.contains(issue.id) && !sent.contains(issue.id) {
            pending.insert(issue.id)
        }
        guard access == .allowed, !pending.isEmpty else { return [] }
        return active.filter { issue in
            guard pending.remove(issue.id) != nil else { return false }
            return sent.insert(issue.id).inserted
        }
    }
}

@MainActor
final class WattlineHealthMonitor: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var active: [HealthIssue] = []
    @Published private(set) var deliveryNote: String?
    var onOpenDetails: (() -> Void)?

    private var checks = HealthChecks()
    private var enabled: Bool?
    private var access = HealthAlertDelivery.Access.blocked
    private var delivery = HealthAlertDelivery()
    private var preferenceGeneration = 0
    private var permissionTask: Task<Void, Never>?
    private var center: UNUserNotificationCenter?

    func configure() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        center = .current()
        center?.delegate = self
        applyPreferences()
    }

    func applyPreferences() {
        let value = UserDefaults.standard.bool(forKey: WattlinePreferences.healthAlertsKey)
        guard value != enabled else { return }
        let explicitlyEnabled = enabled == false && value
        enabled = value
        preferenceGeneration += 1
        permissionTask?.cancel()
        permissionTask = nil
        if value {
            refreshAuthorization(requestPermission: explicitlyEnabled)
        } else {
            access = .blocked
            _ = delivery.reconcile(active: active, newAlerts: [], access: access)
            deliveryNote = nil
            center?.removeAllPendingNotificationRequests()
        }
    }

    func refreshAuthorization(requestPermission: Bool = false) {
        guard enabled == true, let center else { return }
        if !requestPermission && permissionTask != nil { return }
        permissionTask?.cancel()
        access = .checking
        permissionTask = Task {
            defer { if !Task.isCancelled { permissionTask = nil } }
            var status = await center.notificationSettings().authorizationStatus
            guard !Task.isCancelled, enabled == true else { return }
            if requestPermission && status == .notDetermined {
                do {
                    _ = try await center.requestAuthorization(options: [.alert])
                    status = await center.notificationSettings().authorizationStatus
                } catch {
                    guard !Task.isCancelled else { return }
                    access = .blocked
                    reconcileDelivery()
                    deliveryNote = "macOS could not enable notifications. Warnings are still available here."
                    return
                }
            }
            guard !Task.isCancelled, enabled == true else { return }
            switch status {
            case .authorized, .provisional:
                access = .allowed
                deliveryNote = nil
            case .notDetermined:
                access = .checking
                deliveryNote = "Turn notifications off and back on to request access from macOS."
            default:
                access = .blocked
                deliveryNote = "To receive banners, allow Wattline in System Settings → Notifications."
            }
            reconcileDelivery()
        }
    }

    func observe(power: PowerReading, uptime: TimeInterval, afterSleep: Bool) {
        publish(checks.observe(power: power, thermal: ProcessInfo.processInfo.thermalState,
                               uptime: uptime, afterSleep: afterSleep))
    }

    func observe(system: SystemSample, uptime: TimeInterval) {
        publish(checks.observe(system: system, uptime: uptime))
    }

    func reset() {
        checks.resetObservations()
        if !active.isEmpty {
            if enabled == true { center?.removePendingNotificationRequests(withIdentifiers: active.map { "health." + $0.id }) }
            active = []
        }
        delivery = HealthAlertDelivery()
    }

    private func publish(_ change: HealthCheckUpdate) {
        if active != change.active {
            let resolved = active.filter { previous in !change.active.contains { $0.id == previous.id } }
            if enabled == true, !resolved.isEmpty {
                center?.removePendingNotificationRequests(withIdentifiers: resolved.map { "health." + $0.id })
            }
            active = change.active
        }
        reconcileDelivery(newAlerts: change.newAlerts)
    }

    private func reconcileDelivery(newAlerts: [HealthIssue] = []) {
        let issues = delivery.reconcile(active: active, newAlerts: newAlerts, access: enabled == true ? access : .blocked)
        guard !issues.isEmpty, let center else { return }
        let generation = preferenceGeneration
        for issue in issues {
            let content = UNMutableNotificationContent()
            content.title = issue.title
            content.body = issue.message
            content.threadIdentifier = "wattline.health"
            center.add(UNNotificationRequest(identifier: "health." + issue.id, content: content, trigger: nil)) { [weak self] error in
                if error != nil {
                    Task { @MainActor in
                        guard let self, self.enabled == true, self.preferenceGeneration == generation,
                              self.active.contains(where: { $0.id == issue.id }) else { return }
                        self.deliveryNote = "macOS could not deliver a notification. Warnings are still available here."
                    }
                }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                             withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        let identifier = notification.request.identifier
        Task { @MainActor in
            let current = active.contains { "health." + $0.id == identifier }
            completion(enabled == true && current ? [.banner, .list] : [])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                             withCompletionHandler completion: @escaping () -> Void) {
        Task { @MainActor in
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier { onOpenDetails?() }
            completion()
        }
    }
}
