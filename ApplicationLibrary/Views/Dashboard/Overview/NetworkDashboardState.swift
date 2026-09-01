import Foundation
import Library

enum NetworkDashboardPhase: Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
}

enum NetworkDashboardState {
    static let defaultServiceLogMaximumLines = 200
    static let defaultServiceLogMaximumCharacters = 65_536

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

    static func serviceLogTail(
        from source: String,
        maximumLines: Int = defaultServiceLogMaximumLines,
        maximumCharacters: Int = defaultServiceLogMaximumCharacters
    ) -> String {
        guard maximumLines > 0, maximumCharacters > 0 else { return "" }
        let lines = source.split(whereSeparator: \.isNewline)
        let lineTail = lines.suffix(maximumLines).joined(separator: "\n")
        return String(lineTail.suffix(maximumCharacters))
    }

    static func readServiceLogTail(
        at url: URL,
        maximumLines: Int = defaultServiceLogMaximumLines,
        maximumCharacters: Int = defaultServiceLogMaximumCharacters
    ) throws -> String {
        guard maximumLines > 0, maximumCharacters > 0 else { return "" }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        let maximumBytes = UInt64(maximumCharacters) * 4
        try handle.seek(toOffset: length > maximumBytes ? length - maximumBytes : 0)
        let data = try handle.readToEnd() ?? Data()
        return serviceLogTail(
            from: String(decoding: data, as: UTF8.self),
            maximumLines: maximumLines,
            maximumCharacters: maximumCharacters
        )
    }

    static func sanitizedDiagnosticText(_ source: String) -> String {
        let replacements = [
            ("([?&](?:token|access_token|key|secret|password)=)[^&\\s]+", "$1<redacted>"),
            (#"(\"(?:password|secret|token|key)\"\s*:\s*\")[^\"]+"#, "$1<redacted>"),
            (#"(Authorization\s*:\s*Bearer\s+)\S+"#, "$1<redacted>"),
            (#"(https?://)[^/\s:@]+:[^@\s/]+@"#, "$1<redacted>@"),
            (#"\b(password|secret|token|key)\s*([=:])\s*[^\s&,}]+"#, "$1$2<redacted>"),
        ]
        return replacements.reduce(source) { value, replacement in
            guard let expression = try? NSRegularExpression(
                pattern: replacement.0,
                options: [.caseInsensitive]
            ) else { return value }
            return expression.stringByReplacingMatches(
                in: value,
                range: NSRange(value.startIndex..., in: value),
                withTemplate: replacement.1
            )
        }
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
        lastConnectionError: String? = nil,
        lastConnectionStage: String? = nil
    ) -> String {
        ["Version: \(version)", "Status: \(status)", "Profile: \(profile)",
         "Group: \(group ?? "Unavailable")", "Node: \(node ?? "Unavailable")",
         "Last connection stage: \(lastConnectionStage ?? "None")",
         "Last connection error: \(lastConnectionError ?? "None")"].joined(separator: "\n")
    }
}
