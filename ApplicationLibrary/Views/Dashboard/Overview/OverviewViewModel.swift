import Foundation
import Libbox
import Library
import NetworkExtension
import SwiftUI
#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

@MainActor
public final class OverviewViewModel: BaseViewModel {
    public struct Dependencies {
        let start: @MainActor () async throws -> Void
        let stop: @MainActor () async throws -> Void
        let waitUntilReady: @MainActor () async throws -> Void
        let setRuleMode: @MainActor () async throws -> Void
        let selectOutbound: @MainActor (_ groupTag: String, _ outboundTag: String) async throws -> Void
        let copy: @MainActor (_ report: String) throws -> Void

        public init(
            start: @escaping @MainActor () async throws -> Void,
            stop: @escaping @MainActor () async throws -> Void,
            waitUntilReady: @escaping @MainActor () async throws -> Void = {},
            setRuleMode: @escaping @MainActor () async throws -> Void,
            selectOutbound: @escaping @MainActor (_ groupTag: String, _ outboundTag: String) async throws -> Void,
            copy: @escaping @MainActor (_ report: String) throws -> Void
        ) {
            self.start = start
            self.stop = stop
            self.waitUntilReady = waitUntilReady
            self.setRuleMode = setRuleMode
            self.selectOutbound = selectOutbound
            self.copy = copy
        }

        @MainActor public static func live(profile: ExtensionProfile, commandClient: CommandClient) -> Dependencies {
            let ruleDependencies = RuleConnectionTransaction.liveDependencies(
                profile: profile, commandClient: commandClient
            )
            return Dependencies(
                start: ruleDependencies.start,
                stop: ruleDependencies.stop,
                waitUntilReady: ruleDependencies.waitUntilReady,
                setRuleMode: ruleDependencies.setRuleMode,
                selectOutbound: { groupTag, outboundTag in
                    try LibboxNewStandaloneCommandClient()!.selectOutbound(groupTag, outboundTag: outboundTag)
                },
                copy: { try OverviewViewModel.writeToClipboard($0) }
            )
        }
    }

    private struct ActionError: LocalizedError {
        let errorDescription: String?

        init(_ description: String) {
            errorDescription = description
        }
    }

    @Published public var reasserting = false
    @Published var phase: NetworkDashboardPhase = .disconnected
    @Published private(set) var pendingSelections: [String: String] = [:]
    @Published private(set) var lastConnectionError: String?
    @Published private(set) var lastConnectionStage: String?
    @Published private(set) var connectionTimeline: [String] = []

    private let dependencies: Dependencies?
    private var startAttemptGeneration: UInt = 0
    private var activeStartAttemptGeneration: UInt?
    private var connectionAttemptStartedAt: Date?

    public override init() {
        dependencies = nil
        super.init()
    }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        super.init()
    }

    func reconcilePhase(with status: NEVPNStatus) {
        if activeStartAttemptGeneration != nil {
            switch status {
            case .invalid, .disconnected:
                let state = status == .invalid ? "invalid" : "disconnected"
                let interruptedStage = lastConnectionStageBeforeDisconnect
                recordStage("Extension disconnected")
                lastConnectionError = "Extension became \(state) while \(interruptedStage.lowercased())"
                invalidateStartAttempt()
                phase = .disconnected
            case .disconnecting:
                invalidateStartAttempt()
                phase = .disconnecting
            case .connecting, .reasserting:
                phase = .connecting
            default:
                break
            }
            return
        }
        if phase == .disconnecting {
            if status == .invalid || status == .disconnected {
                phase = .disconnected
            }
            return
        }

        switch status {
        case .connecting, .reasserting:
            phase = .connecting
        case .connected:
            phase = .connected
        case .disconnecting:
            phase = .disconnecting
        case .invalid, .disconnected:
            if phase == .connected, lastConnectionStage == "Connected" {
                recordStage("Extension disconnected")
                lastConnectionError = "Extension disconnected immediately after startup completed"
            }
            phase = .disconnected
        @unknown default:
            phase = .disconnected
        }
    }

    public func toggleConnection(profile: ExtensionProfile, environments: ExtensionEnvironments) async {
        guard activeStartAttemptGeneration == nil else { return }
        reconcilePhase(with: profile.status)
        guard phase != .connecting, phase != .disconnecting else { return }
        let resolvedDependencies = dependencies ?? .live(
            profile: profile, commandClient: environments.commandClient
        )

        switch phase {
        case .disconnected:
            await startRuleConnection(using: resolvedDependencies)
            if phase == .connected {
                environments.commandClient.connect()
            }
        case .connected:
            await stopConnection(using: resolvedDependencies)
            if phase == .disconnected {
                environments.commandClient.disconnect()
            }
        case .connecting, .disconnecting:
            return
        }

        reconcilePhase(with: profile.status)
    }

    func startRuleConnection() async {
        guard let dependencies else { return }
        await startRuleConnection(using: dependencies)
    }

    private func startRuleConnection(using dependencies: Dependencies) async {
        guard phase == .disconnected else { return }
        startAttemptGeneration &+= 1
        let attemptGeneration = startAttemptGeneration
        activeStartAttemptGeneration = attemptGeneration
        phase = .connecting
        lastConnectionError = nil
        if lastConnectionStage != "Subscription ready" {
            beginTimeline()
        }

        do {
            try await RuleConnectionTransaction.run(using: .init(
                start: dependencies.start,
                stop: dependencies.stop,
                waitUntilReady: dependencies.waitUntilReady,
                setRuleMode: dependencies.setRuleMode,
                shouldContinue: { [weak self] in
                    self?.isCurrentStartAttempt(attemptGeneration) == true
                },
                onStage: { [weak self] stage in
                    self?.recordStage(stage.rawValue)
                }
            ))
            guard isCurrentStartAttempt(attemptGeneration) else { return }
            completeStartAttempt(attemptGeneration)
            phase = .connected
            recordStage("Connected")
        } catch is CancellationError {
            return
        } catch let failure as RuleConnectionTransaction.Failure {
            guard isCurrentStartAttempt(attemptGeneration) else { return }
            completeStartAttempt(attemptGeneration)
            phase = .disconnecting
            lastConnectionError = failure.localizedDescription
            alert = AlertState(action: failure.alertAction, error: failure)
        } catch {
            guard isCurrentStartAttempt(attemptGeneration) else { return }
            completeStartAttempt(attemptGeneration)
            phase = .disconnected
            lastConnectionError = error.localizedDescription
            alert = AlertState(action: "start service", error: error)
        }
    }

    func beginConnectionPreparation() {
        lastConnectionError = nil
        beginTimeline()
        recordStage("Preparing subscription")
    }

    func completeConnectionPreparation() {
        recordStage("Subscription ready")
    }

    func failConnectionPreparation(_ error: Error) {
        recordStage("Subscription preparation failed")
        lastConnectionError = error.localizedDescription
        alert = AlertState(action: "prepare subscription", error: error)
    }

    func surfaceDisconnectFailure(_ disconnectAlert: AlertState) {
        recordStage("Extension disconnected")
        lastConnectionError = disconnectAlert.message
        alert = disconnectAlert
    }

    func completeManualConfigurationRefresh() {
        alert = AlertState(
            title: String(localized: "配置更新成功"),
            message: String(localized: "sing.conf 已重新下载并通过校验。")
        )
    }

    func failManualConfigurationRefresh(_ error: Error) {
        lastConnectionError = error.localizedDescription
        alert = AlertState(action: "refresh sing.conf", error: error)
    }

    private func beginTimeline() {
        connectionAttemptStartedAt = Date()
        connectionTimeline = []
        lastConnectionStage = nil
    }

    private func recordStage(_ stage: String) {
        let elapsed = Date().timeIntervalSince(connectionAttemptStartedAt ?? Date())
        lastConnectionStage = stage
        connectionTimeline.append(String(format: "+%.3fs %@", elapsed, stage))
    }

    private var lastConnectionStageBeforeDisconnect: String {
        connectionTimeline.last?
            .split(separator: " ", maxSplits: 1)
            .last
            .map(String.init) ?? "starting"
    }

    private func invalidateStartAttempt() {
        startAttemptGeneration &+= 1
        activeStartAttemptGeneration = nil
    }

    private func isCurrentStartAttempt(_ generation: UInt) -> Bool {
        generation == startAttemptGeneration && activeStartAttemptGeneration == generation
    }

    private func completeStartAttempt(_ generation: UInt) {
        guard activeStartAttemptGeneration == generation else { return }
        activeStartAttemptGeneration = nil
    }

    private func stopConnection(using dependencies: Dependencies) async {
        guard phase == .connected else { return }
        phase = .disconnecting
        do {
            try await dependencies.stop()
        } catch {
            phase = .connected
            alert = AlertState(action: "stop service", error: error)
        }
    }

    public func selectOutbound(groupTag: String, outboundTag: String) async {
        pendingSelections[groupTag] = outboundTag
        let selection = dependencies?.selectOutbound ?? { groupTag, outboundTag in
            try LibboxNewStandaloneCommandClient()!.selectOutbound(groupTag, outboundTag: outboundTag)
        }
        do {
            try await selection(groupTag, outboundTag)
        } catch {
            if pendingSelections[groupTag] == outboundTag {
                pendingSelections[groupTag] = nil
            }
            alert = AlertState(action: "select outbound", error: error)
        }
    }

    func pendingSelection(for groupTag: String) -> String? {
        pendingSelections[groupTag]
    }

    func reconcilePendingSelections(with groups: [OutboundGroup]) {
        for group in groups where pendingSelections[group.tag] == group.selected {
            pendingSelections[group.tag] = nil
        }
    }

    public func copyReport(
        logs: [LogEntry],
        serviceLogs: String = "",
        profileUpdateLogs: String = "",
        version: String,
        status: String,
        profile: String,
        group: String?,
        node: String?
    ) {
        let diagnostics = NetworkDashboardState.diagnostics(
            version: version,
            status: status,
            profile: profile,
            group: group,
            node: node,
            lastConnectionError: lastConnectionError,
            lastConnectionStage: lastConnectionStage
        )
        let runtimeLogs = logs.isEmpty
            ? "No runtime logs captured."
            : logs.map(\.message).joined(separator: "\n")
        let timeline = connectionTimeline.isEmpty ? "No connection attempt captured." : connectionTimeline.joined(separator: "\n")
        let serviceLogTail = NetworkDashboardState.serviceLogTail(from: serviceLogs)
        let sanitizedServiceLogs = serviceLogTail.isEmpty
            ? "No service logs captured."
            : NetworkDashboardState.sanitizedDiagnosticText(serviceLogTail)
        let updateLogs = profileUpdateLogs.isEmpty ? "No profile update logs captured." : profileUpdateLogs
        let report = "\(diagnostics)\n\nConnection timeline:\n\(timeline)" +
            "\n\nRuntime logs:\n\(runtimeLogs)\n\nService logs:\n\(sanitizedServiceLogs)" +
            "\n\nConfiguration and extension diagnostics:\n\(updateLogs)"
        let sanitizedReport = NetworkDashboardState.sanitizedDiagnosticText(report)

        do {
            if let dependencies {
                try dependencies.copy(sanitizedReport)
            } else {
                try Self.writeToClipboard(sanitizedReport)
            }
            alert = AlertState(
                title: String(localized: "Report Bug"),
                message: String(localized: "日志已复制，请发送给 Jay。")
            )
        } catch {
            alert = AlertState(action: "copy report", error: error)
        }
    }

    private static func writeToClipboard(_ report: String) throws {
        #if os(iOS)
            UIPasteboard.general.string = report
        #elseif os(macOS)
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(report, forType: .string) else {
                throw ActionError("The clipboard rejected the report")
            }
        #else
            throw ActionError("Clipboard writing is unavailable on this platform")
        #endif
    }

    public func switchProfile(_ profileID: Int64, profile: ExtensionProfile, environments: ExtensionEnvironments) async {
        await SharedPreferences.selectedProfileID.set(profileID)
        environments.selectedProfileUpdate.send()

        if profile.status.isConnected {
            do {
                try await profile.reloadService()
            } catch {
                alert = AlertState(action: "reload service", error: error)
            }
        }
        reasserting = false
    }

    public nonisolated func setSystemProxyEnabled(_ enabled: Bool, profile: ExtensionProfile) async {
        do {
            await SharedPreferences.systemProxyEnabled.set(enabled)
            if enabled {
                try LibboxNewStandaloneCommandClient()!.setSystemProxyEnabled(enabled)
            } else {
                await MainActor.run { reasserting = true }
                try await profile.restart()
                await MainActor.run { reasserting = false }
            }
        } catch {
            await MainActor.run { alert = AlertState(action: "update system proxy settings", error: error) }
        }
    }
}
