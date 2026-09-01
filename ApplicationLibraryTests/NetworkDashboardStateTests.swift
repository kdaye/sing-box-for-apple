import XCTest
@testable import ApplicationLibrary
import Libbox
import Library

@MainActor
final class NetworkDashboardStateTests: XCTestCase {
    func testScreenshotModeRequiresExplicitFastlaneArgument() {
        XCTAssertFalse(Variant.isScreenshotMode(arguments: ["SFI"]))
        XCTAssertTrue(Variant.isScreenshotMode(arguments: ["SFI", "-FASTLANE_SNAPSHOT"]))
    }

    func testDownloadProgressUsesTransferredAndTotalBytes() {
        XCTAssertEqual(NetworkDashboardState.downloadProgress(transferred: 3, total: 12), 0.25)
        XCTAssertEqual(NetworkDashboardState.downloadProgress(transferred: 20, total: 12), 1)
        XCTAssertNil(NetworkDashboardState.downloadProgress(transferred: 3, total: 0))
    }

    func testRuleSetPreparationStatusUsesLatestMatchingRuntimeLog() {
        let logs = [
            LogEntry(level: 4, message: "starting service"),
            LogEntry(level: 4, message: "download rule-set geosite-cn"),
            LogEntry(level: 4, message: "download rule-set geoip-cn"),
        ]

        XCTAssertEqual(
            NetworkDashboardState.ruleSetPreparationStatus(from: logs),
            "download rule-set geoip-cn"
        )

        XCTAssertEqual(
            NetworkDashboardState.ruleSetPreparationStatus(
                fromLogText: "starting service\ndownload rule_set geosite-cn\ndownload rule-set geoip-cn\n"
            ),
            "download rule-set geoip-cn"
        )
    }

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

    func testDisconnectClearsTrafficUntilNextConnectionStatus() {
        let client = CommandClient(.status)
        client.setupMockData()

        XCTAssertNotNil(client.status)

        client.disconnect()

        XCTAssertNil(client.status)
        XCTAssertEqual(client.uplinkHistory, Array(repeating: 0, count: 30))
        XCTAssertEqual(client.downlinkHistory, Array(repeating: 0, count: 30))
    }

    func testDashboardMockDataIncludesASelectablePrimaryGroup() {
        let client = CommandClient(.groups)
        client.setupMockData()

        let groups = NetworkNodePicker.presentationGroups(from: client.groups)

        XCTAssertEqual(NetworkDashboardState.primaryGroup(in: groups)?.tag, "Auto")
        XCTAssertEqual(NetworkDashboardState.selectedNode(in: groups), "Tokyo")
    }

    func testScreenshotDashboardFixtureIncludesSelectableNodes() {
        let groups = NetworkDashboardState.screenshotGroups

        XCTAssertEqual(NetworkDashboardState.primaryGroup(in: groups)?.items.map(\.tag), ["Tokyo", "Singapore", "Hong Kong"])
        XCTAssertEqual(NetworkDashboardState.selectedNode(in: groups), "Tokyo")
    }

    func testPrimaryGroupIsFirstSelectableGroup() {
        let groups = [
            OutboundGroup(tag: "auto", type: "urltest", selected: "a", selectable: false, isExpand: false, items: []),
            OutboundGroup(tag: "proxy", type: "selector", selected: "hk", selectable: true, isExpand: false, items: []),
        ]
        XCTAssertEqual(NetworkDashboardState.primaryGroup(in: groups)?.tag, "proxy")
    }

    func testSelectedNodeUsesAuthoritativeGroupSelection() {
        let groups = [
            OutboundGroup(tag: "auto", type: "urltest", selected: "a", selectable: false, isExpand: false, items: []),
            OutboundGroup(tag: "proxy", type: "selector", selected: "us", selectable: true, isExpand: false, items: []),
        ]

        XCTAssertEqual(NetworkDashboardState.selectedNode(in: groups), "us")
    }

    func testDiagnosticsContainsProfileNodeAndStatus() {
        let value = NetworkDashboardState.diagnostics(
            version: "1.0 (2)", status: "connected", profile: "work", group: "proxy", node: "hk"
        )
        XCTAssertTrue(value.contains("Profile: work"))
        XCTAssertTrue(value.contains("Node: hk"))
        XCTAssertTrue(value.contains("Status: connected"))
        XCTAssertTrue(value.contains("Last connection error: None"))
        XCTAssertTrue(value.contains("Last connection stage: None"))
    }

    func testPreparationFailureSurfacesOriginalErrorAndStage() {
        let model = OverviewViewModel(dependencies: .init(
            start: {}, stop: {}, setRuleMode: {}, selectOutbound: { _, _ in }, copy: { _ in }
        ))

        model.beginConnectionPreparation()
        model.failConnectionPreparation(TestError())

        XCTAssertEqual(model.phase, .disconnected)
        XCTAssertEqual(model.alert?.message, "Failed to prepare subscription\nRule unavailable")
        XCTAssertEqual(model.lastConnectionStage, "Subscription preparation failed")
    }

    func testExtensionDisconnectFailureIsKeptForBugReport() {
        var copied = ""
        let model = OverviewViewModel(dependencies: .init(
            start: {}, stop: {}, setRuleMode: {}, selectOutbound: { _, _ in }, copy: { copied = $0 }
        ))

        model.surfaceDisconnectFailure(AlertState(errorMessage: "libbox: rule-set download: HTTP 403"))
        XCTAssertEqual(model.alert?.message, "libbox: rule-set download: HTTP 403")
        model.copyReport(
            logs: [], version: "1.0 (2)", status: "disconnected", profile: "work", group: nil, node: nil
        )

        XCTAssertTrue(copied.contains("Last connection stage: Extension disconnected"))
        XCTAssertTrue(copied.contains("Last connection error: libbox: rule-set download: HTTP 403"))
    }

    func testBugReportRedactsSecretsFromRuntimeLogsAndConnectionErrors() {
        var copied = ""
        let model = OverviewViewModel(dependencies: .init(
            start: {}, stop: {}, setRuleMode: {}, selectOutbound: { _, _ in }, copy: { copied = $0 }
        ))
        model.surfaceDisconnectFailure(AlertState(errorMessage: "failed https://example.com/a?secret=error-secret"))

        model.copyReport(
            logs: [LogEntry(level: 2, message: "GET https://example.com/b?token=runtime-secret")],
            version: "1.0 (2)", status: "disconnected", profile: "work", group: nil, node: nil
        )

        XCTAssertFalse(copied.contains("error-secret"))
        XCTAssertFalse(copied.contains("runtime-secret"))
        XCTAssertTrue(copied.contains("secret=<redacted>"))
        XCTAssertTrue(copied.contains("token=<redacted>"))
    }

    func testBugReportRedactsJSONBearerAndURLCredentials() {
        let source = #"{"password":"json-secret"} Authorization: Bearer bearer-secret https://user:pass@example.com key=plain-secret"#

        let sanitized = NetworkDashboardState.sanitizedDiagnosticText(source)

        XCTAssertFalse(sanitized.contains("json-secret"))
        XCTAssertFalse(sanitized.contains("bearer-secret"))
        XCTAssertFalse(sanitized.contains("user:pass"))
        XCTAssertFalse(sanitized.contains("plain-secret"))
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

    func testRuleStartTransactionWaitsForReadinessBeforeSettingRule() async throws {
        var events: [String] = []

        try await RuleConnectionTransaction.run(using: .init(
            start: { events.append("start") },
            stop: { events.append("stop") },
            waitUntilReady: { events.append("ready") },
            setRuleMode: { events.append("rule") }
        ))

        XCTAssertEqual(events, ["start", "ready", "rule"])
    }

    func testRuleCommandChannelAllowsSlowRouterStartup() {
        XCTAssertGreaterThanOrEqual(RuleConnectionTransaction.readinessTimeoutSeconds, 300)
    }

    func testRemoteConfigurationRemovesClashWebUIFieldsForAppRuntime() throws {
        let source = """
        {
          "experimental": {
            "clash_api": {
              "external_controller": "127.0.0.1:9090",
              "external_ui": "ui",
              "external_ui_download_url": "https://example.com/ui.zip",
              "external_ui_download_detour": "direct",
              "secret": "shared-secret",
              "default_mode": "rule"
            },
            "cache_file": { "enabled": true }
          },
          "route": { "final": "proxy" }
        }
        """

        let sanitized = try AppRuntimeConfiguration.sanitizeRemote(source)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sanitized.utf8)) as? [String: Any])
        let experimental = try XCTUnwrap(root["experimental"] as? [String: Any])
        let clashAPI = try XCTUnwrap(experimental["clash_api"] as? [String: Any])

        XCTAssertEqual(clashAPI["default_mode"] as? String, "rule")
        XCTAssertNil(clashAPI["external_controller"])
        XCTAssertNil(clashAPI["external_ui"])
        XCTAssertNil(clashAPI["external_ui_download_url"])
        XCTAssertNil(clashAPI["external_ui_download_detour"])
        XCTAssertNil(clashAPI["secret"])
        XCTAssertEqual((experimental["cache_file"] as? [String: Any])?["enabled"] as? Bool, true)
        XCTAssertEqual((root["route"] as? [String: Any])?["final"] as? String, "proxy")
    }

    func testRuleStartTransactionStopsServiceWhenRuleSetupFails() async {
        var events: [String] = []

        do {
            try await RuleConnectionTransaction.run(using: .init(
                start: { events.append("start") },
                stop: { events.append("stop") },
                waitUntilReady: { events.append("ready") },
                setRuleMode: {
                    events.append("rule")
                    throw TestError()
                }
            ))
            XCTFail("Expected Rule setup to fail")
        } catch {
            XCTAssertEqual(events, ["start", "ready", "rule", "stop"])
        }
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

    func testConnectedStatusDoesNotFinishConnectingBeforeRuleIsReady() async {
        let profile = ExtensionProfile.mock
        let originalStatus = profile.status
        profile.status = .disconnected
        defer { profile.status = originalStatus }
        var startCount = 0
        var stopCount = 0
        var ruleCount = 0
        var resumeReadiness: CheckedContinuation<Void, Never>?
        let dependencies = OverviewViewModel.Dependencies(
            start: {
                startCount += 1
                profile.status = .connected
            },
            stop: { stopCount += 1 },
            waitUntilReady: {
                await withCheckedContinuation { resumeReadiness = $0 }
            },
            setRuleMode: { ruleCount += 1 },
            selectOutbound: { _, _ in },
            copy: { _ in }
        )
        let model = OverviewViewModel(dependencies: dependencies)
        let environments = ExtensionEnvironments()

        let firstAction = Task { await model.toggleConnection(profile: profile, environments: environments) }
        while resumeReadiness == nil {
            await Task.yield()
        }
        model.reconcilePhase(with: .connected)
        await model.toggleConnection(profile: profile, environments: environments)

        XCTAssertEqual(model.phase, .connecting)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(ruleCount, 0)

        resumeReadiness?.resume()
        await firstAction.value
        XCTAssertEqual(model.phase, .connected)
        XCTAssertEqual(ruleCount, 1)
    }

    func testExternalConnectingStatusReconcilesToConnected() {
        let model = OverviewViewModel(dependencies: .init(
            start: {}, stop: {}, setRuleMode: {}, selectOutbound: { _, _ in }, copy: { _ in }
        ))

        model.reconcilePhase(with: .connecting)
        XCTAssertEqual(model.phase, .connecting)

        model.reconcilePhase(with: .connected)

        XCTAssertEqual(model.phase, .connected)
    }

    func testDisconnectImmediatelyAfterCompletedStartKeepsDiagnosticError() async {
        let model = OverviewViewModel(dependencies: .init(
            start: {}, stop: {}, setRuleMode: {}, selectOutbound: { _, _ in }, copy: { _ in }
        ))

        await model.startRuleConnection()
        model.reconcilePhase(with: .disconnected)

        XCTAssertEqual(model.lastConnectionStage, "Extension disconnected")
        XCTAssertEqual(model.lastConnectionError, "Extension disconnected immediately after startup completed")
    }

    func testExternalReassertionReconcilesToConnected() {
        let model = OverviewViewModel(dependencies: .init(
            start: {}, stop: {}, setRuleMode: {}, selectOutbound: { _, _ in }, copy: { _ in }
        ))

        model.reconcilePhase(with: .reasserting)
        XCTAssertEqual(model.phase, .connecting)

        model.reconcilePhase(with: .connected)

        XCTAssertEqual(model.phase, .connected)
    }

    func testSiblingCoordinatorReconcilesAnotherCoordinatorsStartToConnected() async {
        var resumeReadiness: CheckedContinuation<Void, Never>?
        let owner = OverviewViewModel(dependencies: .init(
            start: {},
            stop: {},
            waitUntilReady: {
                await withCheckedContinuation { resumeReadiness = $0 }
            },
            setRuleMode: {},
            selectOutbound: { _, _ in },
            copy: { _ in }
        ))
        let sibling = OverviewViewModel(dependencies: .init(
            start: {}, stop: {}, setRuleMode: {}, selectOutbound: { _, _ in }, copy: { _ in }
        ))

        let ownerStart = Task { await owner.startRuleConnection() }
        while resumeReadiness == nil {
            await Task.yield()
        }

        sibling.reconcilePhase(with: .connecting)
        sibling.reconcilePhase(with: .connected)

        XCTAssertEqual(owner.phase, .connecting)
        XCTAssertEqual(sibling.phase, .connected)

        resumeReadiness?.resume()
        await ownerStart.value
    }

    func testDisconnectedStatusInvalidatesStartWaitingForReadiness() async {
        var ruleCount = 0
        var resumeReadiness: CheckedContinuation<Void, Never>?
        let dependencies = OverviewViewModel.Dependencies(
            start: {},
            stop: {},
            waitUntilReady: {
                await withCheckedContinuation { resumeReadiness = $0 }
            },
            setRuleMode: { ruleCount += 1 },
            selectOutbound: { _, _ in },
            copy: { _ in }
        )
        let model = OverviewViewModel(dependencies: dependencies)

        let startAction = Task { await model.startRuleConnection() }
        while resumeReadiness == nil {
            await Task.yield()
        }
        model.reconcilePhase(with: .disconnected)
        resumeReadiness?.resume()
        await startAction.value

        XCTAssertEqual(ruleCount, 0)
        XCTAssertEqual(model.phase, .disconnected)
        XCTAssertEqual(model.lastConnectionStage, "Extension disconnected")
        XCTAssertEqual(model.lastConnectionError, "Extension became disconnected while waiting for rule command channel")
    }

    func testInvalidStatusInvalidatesStartWaitingForReadiness() async {
        var ruleCount = 0
        var resumeReadiness: CheckedContinuation<Void, Never>?
        let dependencies = OverviewViewModel.Dependencies(
            start: {},
            stop: {},
            waitUntilReady: {
                await withCheckedContinuation { resumeReadiness = $0 }
            },
            setRuleMode: { ruleCount += 1 },
            selectOutbound: { _, _ in },
            copy: { _ in }
        )
        let model = OverviewViewModel(dependencies: dependencies)

        let startAction = Task { await model.startRuleConnection() }
        while resumeReadiness == nil {
            await Task.yield()
        }
        model.reconcilePhase(with: .invalid)
        resumeReadiness?.resume()
        await startAction.value

        XCTAssertEqual(ruleCount, 0)
        XCTAssertEqual(model.phase, .disconnected)
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

    func testRuleCleanupKeepsPublicToggleDisconnectingUntilStatusChanges() async {
        let profile = ExtensionProfile.mock
        let originalStatus = profile.status
        profile.status = .disconnected
        defer { profile.status = originalStatus }
        var stopCount = 0
        let dependencies = OverviewViewModel.Dependencies(
            start: { profile.status = .connected },
            stop: { stopCount += 1 },
            setRuleMode: { throw TestError() },
            selectOutbound: { _, _ in },
            copy: { _ in }
        )
        let model = OverviewViewModel(dependencies: dependencies)
        let environments = ExtensionEnvironments()

        await model.toggleConnection(profile: profile, environments: environments)
        await model.toggleConnection(profile: profile, environments: environments)

        XCTAssertEqual(model.phase, .disconnecting)
        XCTAssertEqual(stopCount, 1)

        profile.status = .disconnected
        model.reconcilePhase(with: profile.status)
        XCTAssertEqual(model.phase, .disconnected)
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

        await model.selectOutbound(groupTag: "proxy", outboundTag: "hk")
        await fulfillment(of: [forwarded], timeout: 1)

        XCTAssertEqual(selection?.group, "proxy")
        XCTAssertEqual(selection?.node, "hk")
    }

    func testPendingSelectionWaitsForAuthoritativeGroupConfirmation() async {
        let dependencies = OverviewViewModel.Dependencies(
            start: {}, stop: {}, setRuleMode: {}, selectOutbound: { _, _ in }, copy: { _ in }
        )
        let model = OverviewViewModel(dependencies: dependencies)

        await model.selectOutbound(groupTag: "proxy", outboundTag: "hk")
        XCTAssertEqual(model.pendingSelection(for: "proxy"), "hk")

        model.reconcilePendingSelections(with: [
            OutboundGroup(tag: "proxy", type: "selector", selected: "us", selectable: true, isExpand: false, items: []),
        ])
        XCTAssertEqual(model.pendingSelection(for: "proxy"), "hk")

        model.reconcilePendingSelections(with: [
            OutboundGroup(tag: "proxy", type: "selector", selected: "hk", selectable: true, isExpand: false, items: []),
        ])
        XCTAssertNil(model.pendingSelection(for: "proxy"))
    }

    func testFailedSelectionRollsBackPendingState() async {
        let model = OverviewViewModel(dependencies: .init(
            start: {},
            stop: {},
            setRuleMode: {},
            selectOutbound: { _, _ in throw TestError() },
            copy: { _ in }
        ))

        await model.selectOutbound(groupTag: "proxy", outboundTag: "hk")

        XCTAssertNil(model.pendingSelection(for: "proxy"))
        XCTAssertEqual(model.alert?.message, "Failed to select outbound\nRule unavailable")
    }

    func testCopyReportIncludesDiagnosticsBeforeNonEmptyLogs() {
        var copied = ""
        let dependencies = OverviewViewModel.Dependencies(
            start: {}, stop: {}, setRuleMode: {}, selectOutbound: { _, _ in }, copy: { copied = $0 }
        )
        let model = OverviewViewModel(dependencies: dependencies)

        model.copyReport(
            logs: [LogEntry(level: 4, message: "first"), LogEntry(level: 2, message: "second")],
            version: "1.0 (2)", status: "connected", profile: "work", group: "proxy", node: "hk"
        )

        XCTAssertEqual(
            copied,
            "Version: 1.0 (2)\nStatus: connected\nProfile: work\nGroup: proxy\nNode: hk" +
                "\nLast connection stage: None\nLast connection error: None" +
                "\n\nConnection timeline:\nNo connection attempt captured." +
                "\n\nRuntime logs:\nfirst\nsecond\n\nService logs:\nNo service logs captured." +
                "\n\nConfiguration and extension diagnostics:\nNo profile update logs captured."
        )
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
            "Version: 1.0 (2)\nStatus: disconnected\nProfile: work\nGroup: Unavailable\nNode: Unavailable" +
                "\nLast connection stage: None\nLast connection error: None" +
                "\n\nConnection timeline:\nNo connection attempt captured." +
                "\n\nRuntime logs:\nNo runtime logs captured.\n\nService logs:\nNo service logs captured." +
                "\n\nConfiguration and extension diagnostics:\nNo profile update logs captured."
        )
    }

    func testCopyReportIncludesLastConnectionFailure() async {
        var copied = ""
        let model = OverviewViewModel(dependencies: .init(
            start: { throw TestError() }, stop: {}, setRuleMode: {}, selectOutbound: { _, _ in },
            copy: { copied = $0 }
        ))

        await model.startRuleConnection()
        model.copyReport(
            logs: [], version: "1.0 (2)", status: "disconnected", profile: "work", group: nil, node: nil
        )

        XCTAssertTrue(copied.contains("Last connection error: Rule unavailable"))
        XCTAssertTrue(copied.contains("Last connection stage: Starting extension"))
    }

    func testCopyReportIncludesSanitizedServiceLogTail() {
        var copied = ""
        let model = OverviewViewModel(dependencies: .init(
            start: {}, stop: {}, setRuleMode: {}, selectOutbound: { _, _ in }, copy: { copied = $0 }
        ))

        model.copyReport(
            logs: [],
            serviceLogs: "download rule-set https://example.com/rules.srs?token=private-token\nlibbox: EOF",
            version: "1.0 (2)", status: "disconnected", profile: "work", group: nil, node: nil
        )

        XCTAssertTrue(copied.contains("Service logs:\ndownload rule-set https://example.com/rules.srs?token=<redacted>\nlibbox: EOF"))
        XCTAssertFalse(copied.contains("private-token"))
    }

    func testCopyReportIncludesProfileUpdateDiagnostics() {
        var copied = ""
        let model = OverviewViewModel(dependencies: .init(
            start: {}, stop: {}, setRuleMode: {}, selectOutbound: { _, _ in }, copy: { copied = $0 }
        ))

        model.copyReport(
            logs: [],
            profileUpdateLogs: "2026-08-31T10:00:00.000Z [automatic] not modified (HTTP 304)",
            version: "1.0 (2)", status: "disconnected", profile: "work", group: nil, node: nil
        )

        XCTAssertTrue(copied.contains("Configuration and extension diagnostics:\n2026-08-31T10:00:00.000Z [automatic] not modified (HTTP 304)"))
    }

    func testServiceLogTailKeepsNewestBoundedLines() {
        let source = (1 ... 205).map { "line \($0)" }.joined(separator: "\n")

        let tail = NetworkDashboardState.serviceLogTail(from: source, maximumLines: 200)

        XCTAssertFalse(tail.contains("line 1\n"))
        XCTAssertTrue(tail.hasPrefix("line 6\n"))
        XCTAssertTrue(tail.hasSuffix("line 205"))
    }

    func testServiceLogTailBoundsSingleLongLine() {
        let source = String(repeating: "x", count: 70_000) + "END"

        let tail = NetworkDashboardState.serviceLogTail(from: source)

        XCTAssertLessThanOrEqual(tail.count, 65_536)
        XCTAssertTrue(tail.hasSuffix("END"))
    }

    func testServiceLogFileReaderDoesNotLoadUnboundedPrefix() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try (String(repeating: "old\n", count: 30_000) + "latest error").write(
            to: fileURL, atomically: true, encoding: .utf8
        )

        let tail = try NetworkDashboardState.readServiceLogTail(at: fileURL)

        XCTAssertLessThanOrEqual(tail.count, 65_536)
        XCTAssertTrue(tail.hasSuffix("latest error"))
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
