import XCTest
@testable import ApplicationLibrary
import Library

@MainActor
final class NetworkDashboardStateTests: XCTestCase {
    private struct TestError: LocalizedError {
        let errorDescription: String? = "Rule unavailable"
    }

    private struct ReadinessError: LocalizedError {
        let errorDescription: String? = "Rule readiness timed out"
    }

    private struct StopError: LocalizedError {
        let errorDescription: String? = "Stop unavailable"
    }

    private struct ClipboardError: LocalizedError {
        let errorDescription: String? = "Clipboard unavailable"
    }

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

    func testStartSetsRuleAfterServiceStarts() async {
        var events: [String] = []
        let dependencies = OverviewViewModel.Dependencies(
            start: { events.append("start") },
            stop: { events.append("stop") },
            setRuleMode: { events.append("rule") },
            selectOutbound: { group, node in events.append("\(group):\(node)") },
            copy: { _ in }
        )
        let model = OverviewViewModel(dependencies: dependencies)

        await model.startRuleConnection()

        XCTAssertEqual(events, ["start", "rule"])
        XCTAssertEqual(model.phase, .connected)
    }

    func testStartWaitsForReadinessBeforeSettingRule() async {
        var events: [String] = []
        var resumeReadiness: CheckedContinuation<Void, Never>?
        let dependencies = OverviewViewModel.Dependencies(
            start: { events.append("start") },
            stop: { events.append("stop") },
            waitUntilReady: {
                events.append("wait")
                await withCheckedContinuation { resumeReadiness = $0 }
            },
            setRuleMode: { events.append("rule") },
            selectOutbound: { _, _ in },
            copy: { _ in }
        )
        let model = OverviewViewModel(dependencies: dependencies)

        let startAction = Task { await model.startRuleConnection() }
        while resumeReadiness == nil {
            await Task.yield()
        }
        XCTAssertEqual(events, ["start", "wait"])
        resumeReadiness?.resume()
        await startAction.value

        XCTAssertEqual(events, ["start", "wait", "rule"])
    }

    func testReadinessTimeoutStopsStartedServiceWithoutSettingRule() async {
        var events: [String] = []
        let dependencies = OverviewViewModel.Dependencies(
            start: { events.append("start") },
            stop: { events.append("stop") },
            waitUntilReady: {
                events.append("wait")
                throw ReadinessError()
            },
            setRuleMode: { events.append("rule") },
            selectOutbound: { _, _ in },
            copy: { _ in }
        )
        let model = OverviewViewModel(dependencies: dependencies)

        await model.startRuleConnection()

        XCTAssertEqual(events, ["start", "wait", "stop"])
        XCTAssertEqual(model.phase, .disconnecting)
        XCTAssertEqual(model.alert?.message, "Failed to prepare Rule connection\nRule readiness timed out")
    }

    func testRuleFailureStopsStartedServiceAndSurfacesError() async {
        var events: [String] = []
        let dependencies = OverviewViewModel.Dependencies(
            start: { events.append("start") },
            stop: { events.append("stop") },
            setRuleMode: {
                events.append("rule")
                throw TestError()
            },
            selectOutbound: { _, _ in },
            copy: { _ in }
        )
        let model = OverviewViewModel(dependencies: dependencies)

        await model.startRuleConnection()

        XCTAssertEqual(events, ["start", "rule", "stop"])
        XCTAssertEqual(model.phase, .disconnecting)
        XCTAssertEqual(model.alert?.message, "Failed to set Rule mode\nRule unavailable")
    }

    func testCleanupStopFailureIsCombinedAndDoesNotClaimDisconnected() async {
        var events: [String] = []
        let dependencies = OverviewViewModel.Dependencies(
            start: { events.append("start") },
            stop: {
                events.append("stop")
                throw StopError()
            },
            setRuleMode: {
                events.append("rule")
                throw TestError()
            },
            selectOutbound: { _, _ in },
            copy: { _ in }
        )
        let model = OverviewViewModel(dependencies: dependencies)

        await model.startRuleConnection()

        XCTAssertEqual(events, ["start", "rule", "stop"])
        XCTAssertEqual(model.phase, .disconnecting)
        XCTAssertEqual(
            model.alert?.message,
            "Failed to set Rule mode and stop service\nRule mode failed: Rule unavailable\nStopping service also failed: Stop unavailable"
        )
    }

    func testStartRejectsDuplicateActionWhileConnecting() async {
        var startCount = 0
        var resumeFirstStart: CheckedContinuation<Void, Never>?
        let dependencies = OverviewViewModel.Dependencies(
            start: {
                startCount += 1
                if startCount == 1 {
                    await withCheckedContinuation { continuation in
                        resumeFirstStart = continuation
                    }
                }
            },
            stop: {},
            setRuleMode: {},
            selectOutbound: { _, _ in },
            copy: { _ in }
        )
        let model = OverviewViewModel(dependencies: dependencies)
        let profile = ExtensionProfile.mock
        let originalStatus = profile.status
        profile.status = .disconnected
        defer { profile.status = originalStatus }
        let environments = ExtensionEnvironments()

        let firstAction = Task { await model.toggleConnection(profile: profile, environments: environments) }
        while startCount == 0 {
            await Task.yield()
        }
        await model.toggleConnection(profile: profile, environments: environments)

        XCTAssertEqual(startCount, 1)
        resumeFirstStart?.resume()
        await firstAction.value
    }

    func testConnectedToggleStopsServiceOnce() async {
        var stopCount = 0
        let dependencies = OverviewViewModel.Dependencies(
            start: {},
            stop: { stopCount += 1 },
            setRuleMode: {},
            selectOutbound: { _, _ in },
            copy: { _ in }
        )
        let model = OverviewViewModel(dependencies: dependencies)
        let profile = ExtensionProfile.mock
        let originalStatus = profile.status
        profile.status = .connected
        defer { profile.status = originalStatus }

        await model.toggleConnection(profile: profile, environments: ExtensionEnvironments())

        XCTAssertEqual(stopCount, 1)
    }

    func testSelectionForwardsGroupAndOutboundTags() async {
        var selection: (group: String, node: String)?
        let forwarded = expectation(description: "selection forwarded")
        let dependencies = OverviewViewModel.Dependencies(
            start: {},
            stop: {},
            setRuleMode: {},
            selectOutbound: { group, node in
                selection = (group, node)
                forwarded.fulfill()
            },
            copy: { _ in }
        )
        let model = OverviewViewModel(dependencies: dependencies)

        model.selectOutbound(groupTag: "proxy", outboundTag: "hk")
        await fulfillment(of: [forwarded], timeout: 1)

        XCTAssertEqual(selection?.group, "proxy")
        XCTAssertEqual(selection?.node, "hk")
    }

    func testCopyReportJoinsNonEmptyLogsWithNewlines() {
        var copied = ""
        let dependencies = OverviewViewModel.Dependencies(
            start: {}, stop: {}, setRuleMode: {}, selectOutbound: { _, _ in }, copy: { copied = $0 }
        )
        let model = OverviewViewModel(dependencies: dependencies)

        model.copyReport(
            logs: [LogEntry(level: 4, message: "first"), LogEntry(level: 2, message: "second")],
            version: "1.0 (2)", status: "connected", profile: "work", group: "proxy", node: "hk"
        )

        XCTAssertEqual(copied, "first\nsecond")
        XCTAssertEqual(model.alert?.title, "Report Bug")
        XCTAssertEqual(model.alert?.message, "日志已复制，请发送给 Jay。")
    }

    func testCopyReportUsesDiagnosticsWhenLogsAreEmpty() {
        var copied = ""
        let dependencies = OverviewViewModel.Dependencies(
            start: {}, stop: {}, setRuleMode: {}, selectOutbound: { _, _ in }, copy: { copied = $0 }
        )
        let model = OverviewViewModel(dependencies: dependencies)

        model.copyReport(
            logs: [], version: "1.0 (2)", status: "disconnected", profile: "work", group: nil, node: nil
        )

        XCTAssertEqual(
            copied,
            "Version: 1.0 (2)\nStatus: disconnected\nProfile: work\nGroup: Unavailable\nNode: Unavailable"
        )
    }

    func testCopyReportSurfacesClipboardFailureWithoutSuccessAlert() {
        let dependencies = OverviewViewModel.Dependencies(
            start: {}, stop: {}, setRuleMode: {}, selectOutbound: { _, _ in },
            copy: { _ in throw ClipboardError() }
        )
        let model = OverviewViewModel(dependencies: dependencies)

        model.copyReport(
            logs: [LogEntry(level: 4, message: "first")],
            version: "1.0 (2)", status: "connected", profile: "work", group: "proxy", node: "hk"
        )

        XCTAssertEqual(model.alert?.title, "Error")
        XCTAssertEqual(model.alert?.message, "Failed to copy report\nClipboard unavailable")
    }
}
