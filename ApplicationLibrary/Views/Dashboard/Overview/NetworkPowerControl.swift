import Libbox
import SwiftUI

#if !os(tvOS)
    struct NetworkPowerControl: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        let phase: NetworkDashboardPhase
        let status: LibboxStatusMessage?
        let action: () -> Void

        private var isConnected: Bool {
            phase == .connected
        }

        private var isTransitioning: Bool {
            phase == .connecting || phase == .disconnecting
        }

        private var stateLabel: String {
            switch phase {
            case .disconnected:
                return String(localized: "DISCONNECTED")
            case .connecting:
                return String(localized: "CONNECTING")
            case .connected:
                return String(localized: "CONNECTED")
            case .disconnecting:
                return String(localized: "DISCONNECTING")
            }
        }

        private var trafficTotal: String {
            guard let status, status.trafficAvailable else { return "—" }
            return LibboxFormatBytes(NetworkDashboardState.safeTrafficTotal(
                uplink: status.uplinkTotal,
                downlink: status.downlinkTotal
            ))
        }

        private var uplink: String {
            guard let status, status.trafficAvailable else { return "—" }
            return "\(LibboxFormatBytes(status.uplink))/s"
        }

        private var downlink: String {
            guard let status, status.trafficAvailable else { return "—" }
            return "\(LibboxFormatBytes(status.downlink))/s"
        }

        var body: some View {
            GeometryReader { geometry in
                let plateWidth = min(geometry.size.width, NetworkDashboardStyle.plateMaxWidth)
                let ringDiameter = min(plateWidth * 0.725, NetworkDashboardStyle.ringDiameter)
                let controlDiameter = min(plateWidth * 0.6, NetworkDashboardStyle.controlDiameter)

                ZStack {
                    insetPlate(width: plateWidth)
                    outerRing(diameter: ringDiameter)
                    powerButton(diameter: controlDiameter)
                }
                .frame(width: plateWidth, height: plateWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: NetworkDashboardStyle.plateMaxWidth)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: phase)
        }

        private func insetPlate(width: CGFloat) -> some View {
            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .fill(NetworkDashboardStyle.background)
                .frame(width: width, height: width)
                .shadow(color: .white.opacity(0.95), radius: 16, x: -10, y: -10)
                .shadow(color: NetworkDashboardStyle.ink.opacity(0.12), radius: 18, x: 11, y: 11)
                .overlay {
                    RoundedRectangle(cornerRadius: 42, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [NetworkDashboardStyle.ink.opacity(0.08), .white.opacity(0.9)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2
                        )
                        .padding(1)
                }
        }

        private func outerRing(diameter: CGFloat) -> some View {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.white, NetworkDashboardStyle.background, NetworkDashboardStyle.ink.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: diameter, height: diameter)
                .shadow(color: .white.opacity(0.9), radius: 9, x: -6, y: -6)
                .shadow(color: NetworkDashboardStyle.ink.opacity(0.18), radius: 12, x: 7, y: 8)
        }

        private func powerButton(diameter: CGFloat) -> some View {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(isConnected ? NetworkDashboardStyle.connected : NetworkDashboardStyle.background)
                        .overlay {
                            Circle()
                                .stroke(.white.opacity(isConnected ? 0.35 : 0.85), lineWidth: 1)
                        }
                        .shadow(
                            color: isConnected
                                ? NetworkDashboardStyle.connected.opacity(reduceMotion ? 0.18 : 0.42)
                                : NetworkDashboardStyle.ink.opacity(0.14),
                            radius: isConnected ? (reduceMotion ? 8 : 22) : 10,
                            x: isConnected ? 0 : 5,
                            y: isConnected ? 0 : 6
                        )

                    if isConnected {
                        connectedReadout
                    } else {
                        inactiveReadout
                    }
                }
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isTransitioning)
            .accessibilityIdentifier("network.power")
            .accessibilityLabel(String(localized: "Network power"))
            .accessibilityValue(stateLabel)
            .accessibilityHint(isConnected
                ? String(localized: "Stops the network service")
                : String(localized: "Starts a Rule connection"))
        }

        private var inactiveReadout: some View {
            VStack(spacing: 12) {
                if isTransitioning, !reduceMotion {
                    ProgressView()
                        .controlSize(.large)
                        .tint(NetworkDashboardStyle.connectedInk)
                } else {
                    Image(systemName: isTransitioning ? "hourglass" : "power")
                        .font(.system(size: 34, weight: .medium))
                }

                Text(stateLabel)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .kerning(1.5)
            }
            .foregroundStyle(NetworkDashboardStyle.ink)
        }

        private var connectedReadout: some View {
            VStack(spacing: 6) {
                Image(systemName: "power")
                    .font(.system(size: 25, weight: .bold))

                Text(stateLabel)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .kerning(1.3)

                Text(trafficTotal)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
                    .accessibilityIdentifier("network.trafficTotal")
                    .accessibilityLabel(String(localized: "Total traffic"))

                Text(String(localized: "TOTAL TRAFFIC"))
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .kerning(1.1)

                HStack(spacing: 13) {
                    trafficRate(symbol: "↑", value: uplink, label: String(localized: "Upload rate"), identifier: "network.uplink")
                    trafficRate(symbol: "↓", value: downlink, label: String(localized: "Download rate"), identifier: "network.downlink")
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 13)
            .foregroundStyle(NetworkDashboardStyle.connectedInk)
        }

        private func trafficRate(symbol: String, value: String, label: String, identifier: String) -> some View {
            VStack(spacing: 1) {
                Text(symbol)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                Text(value)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(label)
            .accessibilityValue(value)
        }
    }
#endif
