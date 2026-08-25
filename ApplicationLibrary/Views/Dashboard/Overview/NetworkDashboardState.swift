import Foundation
import Library

enum NetworkDashboardPhase: Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
}

enum NetworkDashboardState {
    static func safeTrafficTotal(uplink: Int64, downlink: Int64) -> Int64 {
        let (sum, overflow) = uplink.addingReportingOverflow(downlink)
        return overflow ? .max : max(0, sum)
    }

    static func primaryGroup(in groups: [OutboundGroup]) -> OutboundGroup? {
        groups.first(where: { $0.selectable })
    }

    static func diagnostics(version: String, status: String, profile: String, group: String?, node: String?) -> String {
        ["Version: \(version)", "Status: \(status)", "Profile: \(profile)",
         "Group: \(group ?? "Unavailable")", "Node: \(node ?? "Unavailable")"].joined(separator: "\n")
    }
}
