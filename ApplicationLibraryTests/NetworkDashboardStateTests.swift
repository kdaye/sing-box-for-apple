import XCTest
@testable import ApplicationLibrary
import Library

final class NetworkDashboardStateTests: XCTestCase {
    func testTrafficTotalSaturatesInsteadOfOverflowing() {
        XCTAssertEqual(NetworkDashboardState.safeTrafficTotal(uplink: .max, downlink: 1), .max)
    }

    func testPrimaryGroupIsFirstSelectableGroup() {
        let groups = [
            OutboundGroup(tag: "auto", type: "urltest", selected: "a", selectable: false, isExpand: false, items: []),
            OutboundGroup(tag: "proxy", type: "selector", selected: "hk", selectable: true, isExpand: false, items: []),
        ]
        XCTAssertEqual(NetworkDashboardState.primaryGroup(in: groups)?.tag, "proxy")
    }

    func testDiagnosticsContainsProfileNodeAndStatus() {
        let value = NetworkDashboardState.diagnostics(
            version: "1.0 (2)", status: "connected", profile: "work", group: "proxy", node: "hk"
        )
        XCTAssertTrue(value.contains("Profile: work"))
        XCTAssertTrue(value.contains("Node: hk"))
        XCTAssertTrue(value.contains("Status: connected"))
    }
}
