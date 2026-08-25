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

        public static func live(profile: ExtensionProfile, commandClient: CommandClient) -> Dependencies {
            Dependencies(
                start: { try await profile.start() },
                stop: { try await profile.stop() },
                waitUntilReady: {
                    try await OverviewViewModel.waitForRuleReadiness(
                        profile: profile, commandClient: commandClient
                    )
                },
                setRuleMode: { try LibboxNewStandaloneCommandClient()!.setClashMode("rule") },
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

    private static let readinessAttempts = 100
    private static let readinessPollNanoseconds: UInt64 = 100_000_000

    @Published public var reasserting = false
    @Published var phase: NetworkDashboardPhase = .disconnected

    private let dependencies: Dependencies?

    public override init() {
        dependencies = nil
        super.init()
    }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        super.init()
    }

    func reconcilePhase(with status: NEVPNStatus) {
        if phase == .connecting {
            switch status {
            case .invalid, .disconnected:
                phase = .disconnected
            case .disconnecting:
                phase = .disconnecting
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
            phase = .disconnected
        @unknown default:
            phase = .disconnected
        }
    }

    public func toggleConnection(profile: ExtensionProfile, environments: ExtensionEnvironments) async {
        guard phase != .connecting, phase != .disconnecting else { return }
        reconcilePhase(with: profile.status)
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
        phase = .connecting

        do {
            try await dependencies.start()
        } catch {
            phase = .disconnected
            alert = AlertState(action: "start service", error: error)
            return
        }

        do {
            try await dependencies.waitUntilReady()
        } catch {
            await cleanUpFailedStart(
                error, action: "prepare Rule connection", failureLabel: "Rule connection preparation",
                dependencies: dependencies
            )
            return
        }

        do {
            try await dependencies.setRuleMode()
            phase = .connected
        } catch {
            await cleanUpFailedStart(
                error, action: "set Rule mode", failureLabel: "Rule mode", dependencies: dependencies
            )
        }
    }

    private func cleanUpFailedStart(
        _ originalError: Error,
        action: String,
        failureLabel: String,
        dependencies: Dependencies
    ) async {
        phase = .disconnecting
        do {
            try await dependencies.stop()
            alert = AlertState(action: action, error: originalError)
        } catch {
            let combinedError = ActionError(
                "\(failureLabel) failed: \(originalError.localizedDescription)\n" +
                    "Stopping service also failed: \(error.localizedDescription)"
            )
            alert = AlertState(action: "\(action) and stop service", error: combinedError)
        }
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

    public func selectOutbound(groupTag: String, outboundTag: String) {
        let selection = dependencies?.selectOutbound ?? { groupTag, outboundTag in
            try LibboxNewStandaloneCommandClient()!.selectOutbound(groupTag, outboundTag: outboundTag)
        }
        Task { @MainActor [weak self] in
            do {
                try await selection(groupTag, outboundTag)
            } catch {
                self?.alert = AlertState(action: "select outbound", error: error)
            }
        }
    }

    public func copyReport(
        logs: [LogEntry],
        version: String,
        status: String,
        profile: String,
        group: String?,
        node: String?
    ) {
        let report = logs.isEmpty
            ? NetworkDashboardState.diagnostics(
                version: version, status: status, profile: profile, group: group, node: node
            )
            : logs.map(\.message).joined(separator: "\n")

        do {
            if let dependencies {
                try dependencies.copy(report)
            } else {
                try Self.writeToClipboard(report)
            }
            alert = AlertState(
                title: String(localized: "Report Bug"),
                message: String(localized: "日志已复制，请发送给 Jay。")
            )
        } catch {
            alert = AlertState(action: "copy report", error: error)
        }
    }

    private static func waitForRuleReadiness(
        profile: ExtensionProfile,
        commandClient: CommandClient
    ) async throws {
        var observedStarting = false
        for attempt in 0 ..< readinessAttempts {
            try Task.checkCancellation()

            switch profile.status {
            case .connecting:
                observedStarting = true
            case .connected, .reasserting:
                observedStarting = true
                commandClient.connect()
                if commandClient.isConnected {
                    return
                }
            case .disconnected, .invalid:
                if observedStarting {
                    throw ActionError("Service disconnected before Rule mode was ready")
                }
            default:
                break
            }

            if attempt + 1 < readinessAttempts {
                try await Task.sleep(nanoseconds: readinessPollNanoseconds)
            }
        }
        throw ActionError("Timed out waiting for the Rule command channel")
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
