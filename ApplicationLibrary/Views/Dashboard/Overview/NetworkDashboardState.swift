import Foundation
import Library

enum NetworkDashboardPhase: Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
}

enum NetworkDashboardState {
    static func downloadProgress(transferred: Int64, total: Int64) -> Double? {
        guard total > 0 else { return nil }
        return min(max(Double(transferred) / Double(total), 0), 1)
    }

    static func ruleSetPreparationStatus(from logs: [LogEntry]) -> String? {
        logs.last(where: { log in
            let message = log.message.lowercased()
            return message.contains("rule-set") || message.contains("rule_set") ||
                message.contains("rule set") || message.contains("ruleset")
        })?.message
    }

    static func ruleSetPreparationStatus(fromLogText source: String) -> String? {
        source.split(whereSeparator: \.isNewline).reversed().first(where: { line in
            let message = line.lowercased()
            return message.contains("rule-set") || message.contains("rule_set") ||
                message.contains("rule set") || message.contains("ruleset")
        }).map(String.init)
    }

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

    static func diagnostics(
        version: String,
        status: String,
        profile: String,
        group: String?,
        node: String?,
        lastConnectionError: String? = nil
    ) -> String {
        ["Version: \(version)", "Status: \(status)", "Profile: \(profile)",
         "Group: \(group ?? "Unavailable")", "Node: \(node ?? "Unavailable")",
         "Last connection error: \(lastConnectionError ?? "None")"].joined(separator: "\n")
    }
}
