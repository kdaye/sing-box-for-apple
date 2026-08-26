import Foundation
import Libbox
import NetworkExtension

@MainActor
public enum RuleConnectionTransaction {
    public struct Dependencies {
        public let start: @MainActor () async throws -> Void
        public let stop: @MainActor () async throws -> Void
        public let waitUntilReady: @MainActor () async throws -> Void
        public let setRuleMode: @MainActor () async throws -> Void
        public let shouldContinue: @MainActor () -> Bool

        public init(
            start: @escaping @MainActor () async throws -> Void,
            stop: @escaping @MainActor () async throws -> Void,
            waitUntilReady: @escaping @MainActor () async throws -> Void,
            setRuleMode: @escaping @MainActor () async throws -> Void,
            shouldContinue: @escaping @MainActor () -> Bool = { true }
        ) {
            self.start = start
            self.stop = stop
            self.waitUntilReady = waitUntilReady
            self.setRuleMode = setRuleMode
            self.shouldContinue = shouldContinue
        }
    }

    public enum Failure: LocalizedError {
        case readiness(Error, stopError: Error?)
        case ruleMode(Error, stopError: Error?)

        public var action: String {
            switch self {
            case .readiness:
                return "prepare Rule connection"
            case .ruleMode:
                return "set Rule mode"
            }
        }

        public var errorDescription: String? {
            let failureLabel: String
            let originalError: Error
            let stopError: Error?

            switch self {
            case let .readiness(error, cleanupError):
                failureLabel = "Rule connection preparation"
                originalError = error
                stopError = cleanupError
            case let .ruleMode(error, cleanupError):
                failureLabel = "Rule mode"
                originalError = error
                stopError = cleanupError
            }

            guard let stopError else {
                return originalError.localizedDescription
            }
            return "\(failureLabel) failed: \(originalError.localizedDescription)\n" +
                "Stopping service also failed: \(stopError.localizedDescription)"
        }

        public var alertAction: String {
            switch self {
            case let .readiness(_, stopError), let .ruleMode(_, stopError):
                return stopError == nil ? action : "\(action) and stop service"
            }
        }
    }

    private struct ReadinessError: LocalizedError {
        let errorDescription: String?
    }

    private static let readinessAttempts = 100
    private static let readinessPollNanoseconds: UInt64 = 100_000_000

    public static func run(using dependencies: Dependencies) async throws {
        try checkContinuation(using: dependencies)
        try await dependencies.start()

        do {
            try checkContinuation(using: dependencies)
            try await dependencies.waitUntilReady()
            try checkContinuation(using: dependencies)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw await failure(for: error, stage: .readiness, dependencies: dependencies)
        }

        do {
            try await dependencies.setRuleMode()
            try checkContinuation(using: dependencies)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw await failure(for: error, stage: .ruleMode, dependencies: dependencies)
        }
    }

    public static func run(profile: ExtensionProfile) async throws {
        let commandClient = CommandClient(.status)
        defer { commandClient.disconnect() }
        try await run(profile: profile, commandClient: commandClient)
    }

    public static func run(profile: ExtensionProfile, commandClient: CommandClient) async throws {
        try await run(using: liveDependencies(profile: profile, commandClient: commandClient))
    }

    public static func liveDependencies(
        profile: ExtensionProfile,
        commandClient: CommandClient
    ) -> Dependencies {
        Dependencies(
            start: { try await profile.start() },
            stop: { try await profile.stop() },
            waitUntilReady: { try await waitUntilReady(profile: profile, commandClient: commandClient) },
            setRuleMode: { try setRuleMode() }
        )
    }

    private enum Stage {
        case readiness
        case ruleMode
    }

    private static func checkContinuation(using dependencies: Dependencies) throws {
        guard dependencies.shouldContinue() else {
            throw CancellationError()
        }
    }

    private static func failure(
        for error: Error,
        stage: Stage,
        dependencies: Dependencies
    ) async -> Failure {
        let stopError: Error?
        do {
            try await dependencies.stop()
            stopError = nil
        } catch {
            stopError = error
        }

        switch stage {
        case .readiness:
            return .readiness(error, stopError: stopError)
        case .ruleMode:
            return .ruleMode(error, stopError: stopError)
        }
    }

    private static func waitUntilReady(
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
                    throw ReadinessError(errorDescription: "Service disconnected before Rule mode was ready")
                }
            default:
                break
            }

            if attempt + 1 < readinessAttempts {
                try await Task.sleep(nanoseconds: readinessPollNanoseconds)
            }
        }
        throw ReadinessError(errorDescription: "Timed out waiting for the Rule command channel")
    }

    private static func setRuleMode() throws {
        guard let commandClient = LibboxNewStandaloneCommandClient() else {
            throw ReadinessError(errorDescription: "Rule command channel is unavailable")
        }
        try commandClient.setClashMode("rule")
    }
}
