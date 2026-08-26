import Foundation
import Library

enum NetworkDashboardPhase: Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
}

enum NetworkDashboardState {
    static let screenshotGroups = [
        OutboundGroup(
            tag: "Auto",
            type: "selector",
            selected: "Tokyo",
            selectable: true,
            isExpand: false,
            items: [
                OutboundGroupItem(
                    tag: "Tokyo", type: "Shadowsocks",
                    urlTestTime: Date(timeIntervalSince1970: 0), urlTestDelay: 42
                ),
                OutboundGroupItem(
                    tag: "Singapore", type: "VMess",
                    urlTestTime: Date(timeIntervalSince1970: 0), urlTestDelay: 68
                ),
                OutboundGroupItem(
                    tag: "Hong Kong", type: "Trojan",
                    urlTestTime: Date(timeIntervalSince1970: 0), urlTestDelay: 91
                ),
            ]
        ),
    ]

    static func safeTrafficTotal(uplink: Int64, downlink: Int64) -> Int64 {
        let (sum, overflow) = uplink.addingReportingOverflow(downlink)
        return overflow ? .max : max(0, sum)
    }

    static func primaryGroup(in groups: [OutboundGroup]) -> OutboundGroup? {
        groups.first(where: { $0.selectable })
    }

    static func selectedNode(in groups: [OutboundGroup]) -> String? {
        primaryGroup(in: groups)?.selected
    }

    static func diagnostics(version: String, status: String, profile: String, group: String?, node: String?) -> String {
        ["Version: \(version)", "Status: \(status)", "Profile: \(profile)",
         "Group: \(group ?? "Unavailable")", "Node: \(node ?? "Unavailable")"].joined(separator: "\n")
    }
}
