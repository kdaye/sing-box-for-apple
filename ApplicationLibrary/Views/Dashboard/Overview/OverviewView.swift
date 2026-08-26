import Foundation
import Libbox
import Library
import SwiftUI

@MainActor
public struct OverviewView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @EnvironmentObject private var profile: ExtensionProfile
    @StateObject private var coordinator = OverviewViewModel()
    @ObservedObject private var configuration: DashboardCardConfiguration

    @Binding private var profileList: [ProfilePreview]
    @Binding private var selectedProfileID: Int64
    @Binding private var systemProxyAvailable: Bool
    @Binding private var systemProxyEnabled: Bool

    public init(
        _ profileList: Binding<[ProfilePreview]>,
        _ selectedProfileID: Binding<Int64>,
        _ systemProxyAvailable: Binding<Bool>,
        _ systemProxyEnabled: Binding<Bool>,
        cardConfiguration: DashboardCardConfiguration
    ) {
        _profileList = profileList
        _selectedProfileID = selectedProfileID
        _systemProxyAvailable = systemProxyAvailable
        _systemProxyEnabled = systemProxyEnabled
        _configuration = ObservedObject(wrappedValue: cardConfiguration)
    }

    public var body: some View {
        Group {
        #if os(tvOS)
            if configuration.isLoading {
                ProgressView()
            } else {
                ScrollView {
                    cardGrid
                        .padding()
                }
            }
        #else
            NetworkDashboardPage(
                profileList: $profileList,
                selectedProfileID: $selectedProfileID,
                profile: profile,
                environments: environments,
                coordinator: coordinator
            )
        #endif
        }
        .alert($coordinator.alert)
        #if os(tvOS)
        .disabled(!Variant.screenshotMode && (!profile.status.isSwitchable || coordinator.reasserting))
        #endif
    }

    @ViewBuilder
    private var cardGrid: some View {
        let visibleCards = configuration.orderedEnabledCards.filter(shouldShowCard)
        let groupedCards = groupCards(visibleCards)

        VStack(spacing: 16) {
            ForEach(Array(groupedCards.enumerated()), id: \.offset) { _, group in
                if group.count == 2 {
                    HStack(spacing: 16) {
                        cardView(for: group[0])
                            .frame(maxWidth: .infinity)
                        cardView(for: group[1])
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    cardView(for: group[0])
                }
            }
        }
    }

    private func groupCards(_ cards: [DashboardCard]) -> [[DashboardCard]] {
        var result: [[DashboardCard]] = []
        var index = 0

        while index < cards.count {
            let card = cards[index]
            if card.isHalfWidth, index + 1 < cards.count, cards[index + 1].isHalfWidth {
                result.append([card, cards[index + 1]])
                index += 2
            } else {
                result.append([card])
                index += 1
            }
        }
        return result
    }

    private func shouldShowCard(_ card: DashboardCard) -> Bool {
        switch card {
        case .status, .connections, .uploadTraffic, .downloadTraffic, .clashMode:
            return Variant.screenshotMode || profile.status.isConnected
        case .httpProxy:
            return (Variant.screenshotMode || profile.status.isConnectedStrict) && systemProxyAvailable
        case .profile:
            return true
        }
    }

    @ViewBuilder
    private func cardView(for card: DashboardCard) -> some View {
        switch card {
        case .status:
            StatusCard()
                .environmentObject(environments.commandClient)
        case .connections:
            ConnectionsCard()
                .environmentObject(environments.commandClient)
        case .uploadTraffic:
            UploadTrafficCard()
                .environmentObject(environments.commandClient)
        case .downloadTraffic:
            DownloadTrafficCard()
                .environmentObject(environments.commandClient)
        case .httpProxy:
            HTTPProxyCard(
                systemProxyAvailable: $systemProxyAvailable,
                systemProxyEnabled: $systemProxyEnabled
            ) { enabled in
                await coordinator.setSystemProxyEnabled(enabled, profile: profile)
            }
        case .clashMode:
            ClashModeCard()
                .environmentObject(environments.commandClient)
        case .profile:
            EmptyView()
        }
    }
}

#if !os(tvOS)
    @MainActor
    private struct NetworkDashboardPage: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Binding private var profileList: [ProfilePreview]
        @Binding private var selectedProfileID: Int64
        @ObservedObject private var profile: ExtensionProfile
        @ObservedObject private var commandClient: CommandClient
        @ObservedObject private var coordinator: OverviewViewModel

        private let environments: ExtensionEnvironments

        @State private var showsNodePicker = false
        @State private var preparationStatus: String?
        @State private var isPreparingDefaultProfile = false

        init(
            profileList: Binding<[ProfilePreview]>,
            selectedProfileID: Binding<Int64>,
            profile: ExtensionProfile,
            environments: ExtensionEnvironments,
            coordinator: OverviewViewModel
        ) {
            _profileList = profileList
            _selectedProfileID = selectedProfileID
            _profile = ObservedObject(wrappedValue: profile)
            _commandClient = ObservedObject(wrappedValue: environments.commandClient)
            _coordinator = ObservedObject(wrappedValue: coordinator)
            self.environments = environments
        }

        private var groups: [OutboundGroup] {
            if Variant.screenshotMode {
                return NetworkDashboardState.screenshotGroups
            }
            return NetworkNodePicker.presentationGroups(from: commandClient.groups)
        }

        private var primaryGroup: OutboundGroup? {
            NetworkDashboardState.primaryGroup(in: groups)
        }

        private var selectedNode: String {
            NetworkDashboardState.selectedNode(in: groups) ?? String(localized: "当前配置自动选择")
        }

        private var selectedGroupName: String? {
            primaryGroup?.tag
        }

        private var selectedProfileName: String {
            profileList.first(where: { $0.id == selectedProfileID })?.name ?? String(selectedProfileID)
        }

        private var version: String {
            "\(Bundle.main.version) (\(Bundle.main.versionNumber))"
        }

        private var footerVersion: String {
            "v\(Bundle.main.version)-build.\(Bundle.main.versionNumber)"
        }

        private var statusDescription: String {
            switch profile.status {
            case .invalid:
                return "invalid"
            case .disconnected:
                return "disconnected"
            case .connecting:
                return "connecting"
            case .connected:
                return "connected"
            case .reasserting:
                return "reasserting"
            case .disconnecting:
                return "disconnecting"
            @unknown default:
                return "unknown"
            }
        }

        var body: some View {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        header

                        Spacer(minLength: 30)

                        NetworkPowerControl(
                            phase: coordinator.phase,
                            status: commandClient.status,
                            preparationStatus: isPreparingDefaultProfile
                                ? String(localized: "正在获取订阅配置…")
                                : preparationStatus
                        ) {
                            Task {
                                await startConnection()
                            }
                        }

                        if coordinator.phase == .connected {
                            nodeSelector
                                .padding(.top, 24)
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                        }

                        Spacer(minLength: 36)

                        reportButton

                        Text(footerVersion)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(NetworkDashboardStyle.ink.opacity(0.38))
                            .padding(.top, 20)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    .frame(width: min(max(geometry.size.width - 32, 0), NetworkDashboardStyle.contentMaxWidth))
                    .frame(minHeight: max(geometry.size.height, 700))
                    .frame(maxWidth: .infinity)
                }
            }
            .background(NetworkDashboardStyle.background.ignoresSafeArea())
            .environment(\.colorScheme, .light)
            .onAppear {
                coordinator.reconcilePhase(with: profile.status)
            }
            .onChangeCompat(of: profile.status) { status in
                coordinator.reconcilePhase(with: status)
            }
            .onReceive(commandClient.$groups) { groups in
                coordinator.reconcilePendingSelections(with: NetworkNodePicker.presentationGroups(from: groups))
            }
            .task(id: coordinator.phase) {
                guard coordinator.phase == .connecting else {
                    preparationStatus = nil
                    return
                }
                let logURL = FilePath.cacheDirectory.appendingPathComponent("stderr.log")
                while !Task.isCancelled, coordinator.phase == .connecting {
                    preparationStatus = await BlockingIO.run { () -> String? in
                        guard let source = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
                        return NetworkDashboardState.ruleSetPreparationStatus(fromLogText: source)
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            .sheet(isPresented: $showsNodePicker) {
                NetworkNodePicker(
                    groups: groups,
                    pendingSelections: coordinator.pendingSelections
                ) { groupTag, outboundTag in
                    Task {
                        await coordinator.selectOutbound(groupTag: groupTag, outboundTag: outboundTag)
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: coordinator.phase)
        }

        private func startConnection() async {
            guard !isPreparingDefaultProfile else { return }
            if !profile.status.isConnected, let ensureDefaultProfile = environments.ensureDefaultProfile {
                // A variant (e.g. SFI) can install this hook to fetch/create its
                // bundled subscription on demand. Run it unconditionally here too -
                // not just when the profile list is empty - since a profile record
                // can already exist locally while the persisted selection is still
                // unset or stale; this hook is also what re-syncs that selection.
                isPreparingDefaultProfile = true
                await ensureDefaultProfile()
                isPreparingDefaultProfile = false
                guard !environments.emptyProfiles else { return }
            }
            await coordinator.toggleConnection(profile: profile, environments: environments)
        }

        private var header: some View {
            HStack(spacing: 9) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(NetworkDashboardStyle.connectedInk)

                Text(String(localized: "网络工具"))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(NetworkDashboardStyle.ink)

                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }

        private var nodeSelector: some View {
            let canSelect = primaryGroup != nil

            return Button {
                showsNodePicker = true
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(NetworkDashboardStyle.connected.opacity(0.22))
                            .frame(width: 38, height: 38)
                        Image(systemName: "server.rack")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(NetworkDashboardStyle.connectedInk)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "当前服务器"))
                            .font(.caption2.weight(.semibold))
                            .kerning(1.2)
                            .foregroundStyle(NetworkDashboardStyle.ink.opacity(0.48))

                        Text(selectedNode)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(NetworkDashboardStyle.ink)
                            .lineLimit(1)
                            .accessibilityIdentifier("network.currentNode")

                        if let selectedGroupName {
                            Text(selectedGroupName)
                                .font(.caption)
                                .foregroundStyle(NetworkDashboardStyle.ink.opacity(0.5))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    Image(systemName: canSelect ? "chevron.right" : "lock.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NetworkDashboardStyle.ink.opacity(0.42))
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 74)
                .background {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.white.opacity(0.62))
                        .shadow(color: .white.opacity(0.9), radius: 8, x: -5, y: -5)
                        .shadow(color: NetworkDashboardStyle.ink.opacity(0.1), radius: 10, x: 6, y: 7)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSelect)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "当前服务器"))
            .accessibilityValue(selectedNode)
        }

        private var reportButton: some View {
            Button {
                coordinator.copyReport(
                    logs: commandClient.logList,
                    version: version,
                    status: statusDescription,
                    profile: selectedProfileName,
                    group: selectedGroupName,
                    node: primaryGroup == nil ? nil : selectedNode
                )
            } label: {
                Label(String(localized: "Report Bug"), systemImage: "ladybug")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(NetworkDashboardStyle.ink)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("network.reportBug")
            .accessibilityLabel(String(localized: "Report Bug"))
        }
    }
#endif
