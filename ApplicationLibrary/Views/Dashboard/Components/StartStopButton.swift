import Library
import NetworkExtension
import SwiftUI

@MainActor
public struct StartStopButton: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    private let showsRuntimeDuration: Bool

    public init(showsRuntimeDuration: Bool = false) {
        self.showsRuntimeDuration = showsRuntimeDuration
    }

    public var body: some View {
        Group {
            if let profile = environments.extensionProfile {
                ToggleConnectionButton(showsRuntimeDuration: showsRuntimeDuration)
                    .environmentObject(profile)
            } else {
                Button {} label: {
                    #if os(tvOS)
                        Image(systemName: "play.fill")
                    #else
                        Label("Start", systemImage: "play.fill")
                    #endif
                }
                .labelStyle(.iconOnly)
                .disabled(true)
            }
        }
        .disabled(environments.emptyProfiles && environments.ensureDefaultProfile == nil)
    }

    private struct ToggleConnectionButton: View {
        @EnvironmentObject private var environments: ExtensionEnvironments
        @EnvironmentObject private var profile: ExtensionProfile
        @StateObject private var coordinator = OverviewViewModel()
        @State private var currentTime = Date()
        @State private var isPreparingDefaultProfile = false
        let showsRuntimeDuration: Bool

        private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

        var body: some View {
            Button {
                Task {
                    await switchProfile(!profile.status.isConnected)
                }
            } label: {
                if isPreparingDefaultProfile {
                    ProgressView()
                } else {
                    #if os(iOS)
                        HStack(spacing: 8) {
                            if showsRuntimeDuration, profile.status.isConnectedStrict, let duration = runtimeDuration {
                                Text(duration)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .fixedSize()
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .trailing).combined(with: .opacity)
                                    ))
                            }

                            if !profile.status.isConnected {
                                Label("Start", systemImage: "play.fill")
                            } else {
                                Label("Stop", systemImage: "stop.fill")
                            }
                        }
                        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: profile.status.isConnectedStrict)
                    #elseif os(tvOS)
                        if !profile.status.isConnected {
                            Image(systemName: "play.fill")
                        } else {
                            Image(systemName: "stop.fill")
                        }
                    #else
                        HStack(spacing: 8) {
                            if profile.status.isConnectedStrict, let duration = runtimeDuration {
                                Text(duration)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .fixedSize()
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .trailing).combined(with: .opacity)
                                    ))
                            }

                            if !profile.status.isConnected {
                                Label("Start", systemImage: "play.fill")
                            } else {
                                Label("Stop", systemImage: "stop.fill")
                            }
                        }
                        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: profile.status.isConnectedStrict)
                    #endif
                }
            }
            .labelStyle(.iconOnly)
            #if os(iOS)
                .modifier(PrimaryTintModifier())
            #endif
                .disabled(
                    !profile.status.isEnabled || coordinator.phase == .connecting || coordinator.phase == .disconnecting || isPreparingDefaultProfile
                )
                .alert($coordinator.alert)
                .onReceive(timer) { _ in
                    guard !Variant.screenshotMode else { return }
                    Task { @MainActor in
                        currentTime = Date()
                    }
                }
                .onChangeCompat(of: profile.status) { status in
                    coordinator.reconcilePhase(with: status)
                    if status == .disconnected {
                        environments.commandClient.disconnect()
                    }
                }
        }

        private var runtimeDuration: String? {
            guard let connectedDate = profile.connectedDate else { return nil }
            let interval: TimeInterval
            if Variant.screenshotMode {
                interval = 3600
            } else {
                interval = currentTime.timeIntervalSince(connectedDate)
            }
            guard interval >= 0 else { return nil }

            let hours = Int(interval) / 3600
            let minutes = Int(interval) / 60 % 60
            let seconds = Int(interval) % 60

            if hours > 0 {
                return String(format: "%d:%02d:%02d", hours, minutes, seconds)
            } else {
                return String(format: "%d:%02d", minutes, seconds)
            }
        }

        private func switchProfile(_ isEnabled: Bool) async {
            if isEnabled, let ensureDefaultProfile = environments.ensureDefaultProfile {
                // Always run this, not just when `emptyProfiles` is true: a profile
                // record can already exist locally while the persisted selection is
                // still unset/stale (e.g. after a reinstall), and this hook is also
                // what re-syncs that selection. Skipping it whenever a profile
                // happens to exist already reintroduces "Missing selected profile".
                isPreparingDefaultProfile = true
                await ensureDefaultProfile()
                isPreparingDefaultProfile = false
                // Preparation may have failed (e.g. no network yet); the hook is
                // responsible for surfacing its own error. Don't attempt to start
                // with nothing to run.
                guard !environments.emptyProfiles else { return }
            }
            await coordinator.toggleConnection(profile: profile, environments: environments)
            if isEnabled, profile.status == .disconnected,
               #available(iOS 16.0, macOS 13.0, tvOS 17.0, *),
               let startupAlert = await profile.checkLastDisconnectError()
            {
                coordinator.alert = startupAlert
            }
        }
    }
}

#if os(iOS)
    private struct PrimaryTintModifier: ViewModifier {
        func body(content: Content) -> some View {
            if #available(iOS 26.0, *), !Variant.debugNoIOS26 {
                content.tint(.primary)
            } else {
                content
            }
        }
    }
#endif
