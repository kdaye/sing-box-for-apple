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
        let setRuleMode: @MainActor () async throws -> Void
        let selectOutbound: @MainActor (_ groupTag: String, _ outboundTag: String) async throws -> Void
        let copy: @MainActor (_ report: String) -> Void

        public init(
            start: @escaping @MainActor () async throws -> Void,
            stop: @escaping @MainActor () async throws -> Void,
            setRuleMode: @escaping @MainActor () async throws -> Void,
            selectOutbound: @escaping @MainActor (_ groupTag: String, _ outboundTag: String) async throws -> Void,
            copy: @escaping @MainActor (_ report: String) -> Void
        ) {
            self.start = start
            self.stop = stop
            self.setRuleMode = setRuleMode
            self.selectOutbound = selectOutbound
            self.copy = copy
        }

        public static func live(profile: ExtensionProfile) -> Dependencies {
            Dependencies(
                start: { try await profile.start() },
                stop: { try await profile.stop() },
                setRuleMode: { try LibboxNewStandaloneCommandClient()!.setClashMode("rule") },
                selectOutbound: { groupTag, outboundTag in
                    try LibboxNewStandaloneCommandClient()!.selectOutbound(groupTag, outboundTag: outboundTag)
                },
                copy: { report in
                    #if os(iOS)
                        UIPasteboard.general.string = report
                    #elseif os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                    #endif
                }
            )
        }
    }

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
        let resolvedDependencies = dependencies ?? .live(profile: profile)

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
            try await dependencies.setRuleMode()
            phase = .connected
        } catch {
            alert = AlertState(action: "set Rule mode", error: error)
            try? await dependencies.stop()
            phase = .disconnected
        }
    }

    private func stopConnection(using dependencies: Dependencies) async {
        guard phase == .connected else { return }
        phase = .disconnecting
        do {
            try await dependencies.stop()
            phase = .disconnected
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

        if let dependencies {
            dependencies.copy(report)
        } else {
            #if os(iOS)
                UIPasteboard.general.string = report
            #elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
            #endif
        }
        alert = AlertState(
            title: String(localized: "Report Bug"),
            message: String(localized: "日志已复制，请发送给 Jay。")
        )
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
