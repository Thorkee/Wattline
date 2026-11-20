import XCTest
@testable import Wattline

final class HealthAlertDeliveryTests: XCTestCase {
    private func issue(_ id: String, severity: HealthIssue.Severity = .warning) -> HealthIssue {
        HealthIssue(id: id, title: id, message: id, severity: severity)
    }

    func testPermissionResolutionDeliversEachCurrentIssueOnceAtItsCurrentSeverity() {
        var delivery = HealthAlertDelivery()
        let warning = issue("thermal")
        let critical = issue("thermal", severity: .critical)
        let power = issue("power")
        XCTAssertTrue(delivery.reconcile(active: [warning], newAlerts: [warning], access: .checking).isEmpty)
        XCTAssertTrue(delivery.reconcile(active: [critical, power], newAlerts: [power, warning], access: .checking).isEmpty)
        XCTAssertEqual(delivery.reconcile(active: [critical, power], newAlerts: [], access: .allowed), [critical, power])
        XCTAssertTrue(delivery.reconcile(active: [critical, power], newAlerts: [critical], access: .allowed).isEmpty)
    }

    func testDisablingOrDeniedAuthorizationDropsPendingAndSuppressesAlreadyActiveBacklog() {
        var delivery = HealthAlertDelivery()
        let critical = issue("thermal", severity: .critical)
        XCTAssertTrue(delivery.reconcile(active: [critical], newAlerts: [critical], access: .checking).isEmpty)
        XCTAssertTrue(delivery.reconcile(active: [critical], newAlerts: [], access: .blocked).isEmpty)
        XCTAssertTrue(delivery.reconcile(active: [critical], newAlerts: [], access: .allowed).isEmpty)
        let power = issue("power")
        XCTAssertTrue(delivery.reconcile(active: [power], newAlerts: [power], access: .blocked).isEmpty)
        XCTAssertTrue(delivery.reconcile(active: [power], newAlerts: [], access: .allowed).isEmpty)
    }

    func testResolutionOrSleepBeforeApprovalDropsOldEpisodeButAllowsNewOne() {
        var delivery = HealthAlertDelivery()
        let power = issue("power")
        XCTAssertTrue(delivery.reconcile(active: [power], newAlerts: [power], access: .checking).isEmpty)
        XCTAssertTrue(delivery.reconcile(active: [], newAlerts: [], access: .checking).isEmpty)
        XCTAssertTrue(delivery.reconcile(active: [power], newAlerts: [], access: .allowed).isEmpty)
        XCTAssertEqual(delivery.reconcile(active: [power], newAlerts: [power], access: .allowed), [power])
        XCTAssertTrue(delivery.reconcile(active: [], newAlerts: [], access: .allowed).isEmpty)
        XCTAssertEqual(delivery.reconcile(active: [power], newAlerts: [power], access: .allowed), [power])
    }
}
