import Foundation
import GRDB
import Libbox
import CryptoKit
import Darwin

public enum AuthenticatedConfigurationURL {
    public static func make(year: Int = Calendar.current.component(.year, from: Date())) throws -> URL {
        let digest = SHA256.hash(data: Data("\(year * 88)sanzhihema".utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.sanzhihema.com"
        components.path = "/sing.conf"
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }
}

public enum ProfileUpdateSource: String, Sendable {
    case initial
    case local
    case manual
    case forced
    case automatic
    case extensionStartup = "extension"
}

public enum ProfileUpdateMode: Sendable, Equatable {
    case initial
    case manual
    case forced
    case automatic

    public var source: ProfileUpdateSource {
        switch self {
        case .initial: .initial
        case .manual: .manual
        case .forced: .forced
        case .automatic: .automatic
        }
    }

    public func requestETag(storedETag: String?) -> String? {
        self == .forced || self == .initial ? nil : storedETag
    }
}

public enum ProfileUpdateDiagnostics {
    public static let maximumFileBytes = 262_144
    public static var defaultFileURL: URL {
        FilePath.cacheDirectory.appendingPathComponent("profile-update.log")
    }

    public static func append(
        source: ProfileUpdateSource,
        event: String,
        at date: Date = Date(),
        fileURL: URL = defaultFileURL
    ) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "\(formatter.string(from: date)) [\(source.rawValue)] \(event)\n"
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(fileURL.path, O_CREAT | O_RDWR | O_APPEND, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            flock(descriptor, LOCK_UN)
            try? handle.close()
        }
        let previousLength = try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        let newLength = previousLength + UInt64(line.utf8.count)
        if newLength > UInt64(maximumFileBytes) {
            let retainedBytes = UInt64(maximumFileBytes / 2)
            try handle.seek(toOffset: newLength - min(newLength, retainedBytes))
            let tail = try handle.readToEnd() ?? Data()
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: tail)
        }
    }

    public static func read(fileURL: URL = defaultFileURL, maximumCharacters: Int = 65_536) throws -> String {
        guard maximumCharacters > 0 else { return "" }
        let descriptor = Darwin.open(fileURL.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_SH) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            flock(descriptor, LOCK_UN)
            try? handle.close()
        }
        let length = try handle.seekToEnd()
        let maximumBytes = UInt64(maximumCharacters) * 4
        try handle.seek(toOffset: length > maximumBytes ? length - maximumBytes : 0)
        let data = try handle.readToEnd() ?? Data()
        return String(String(decoding: data, as: UTF8.self).suffix(maximumCharacters))
    }

    public static func record(source: ProfileUpdateSource, event: String) {
        try? append(source: source, event: event)
    }
}

public enum AppRuntimeConfiguration {
    private static let ignoredClashAPIFields = [
        "external_controller",
        "external_ui",
        "external_ui_download_url",
        "external_ui_download_detour",
        "secret",
    ]

    public static func sanitizeRemote(_ source: String) throws -> String {
        let data = Data(source.utf8)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var experimental = root["experimental"] as? [String: Any],
              var clashAPI = experimental["clash_api"] as? [String: Any]
        else {
            return source
        }

        var changed = false
        for field in ignoredClashAPIFields where clashAPI.removeValue(forKey: field) != nil {
            changed = true
        }
        guard changed else { return source }

        experimental["clash_api"] = clashAPI
        root["experimental"] = experimental
        let sanitized = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: sanitized, as: UTF8.self)
    }
}

public extension Profile {
    static func shouldRedownloadMissingRemoteContent(after error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
    }

    nonisolated func updateRemoteProfile(mode: ProfileUpdateMode = .manual) async throws {
        if type != .remote {
            return
        }
        var url = remoteURL
        if let storedURL = URL(string: remoteURL ?? ""),
           storedURL.host == "www.sanzhihema.com", storedURL.path == "/sing.conf"
        {
            let authenticatedURL = try AuthenticatedConfigurationURL.make().absoluteString
            url = authenticatedURL
            await MainActor.run { remoteURL = authenticatedURL }
        }
        let endpoint = URL(string: url ?? "")?.path ?? "unknown endpoint"
        ProfileUpdateDiagnostics.record(source: mode.source, event: "request started: \(endpoint)")
        let result: ConditionalHTTPResult
        do {
            result = try await HTTPClient.getStringConditionalAsync(
                url,
                etag: mode.requestETag(storedETag: remoteETag)
            )
        } catch {
            ProfileUpdateDiagnostics.record(source: mode.source, event: "download failed: \(error.localizedDescription)")
            throw error
        }
        if case let .notModified(responseETag) = result {
            do {
                await MainActor.run {
                    lastUpdated = Date()
                    if let responseETag {
                        remoteETag = responseETag
                    }
                }
                try await ProfileManager.update(self)
                ProfileUpdateDiagnostics.record(source: mode.source, event: "not modified (HTTP 304)")
            } catch {
                ProfileUpdateDiagnostics.record(source: mode.source, event: "failed to persist HTTP 304 result: \(error.localizedDescription)")
                throw error
            }
            return
        }
        guard case let .modified(downloadedContent, responseETag) = result else {
            return
        }
        ProfileUpdateDiagnostics.record(
            source: mode.source,
            event: "download succeeded (HTTP 2xx, \(downloadedContent.utf8.count) bytes); validating"
        )
        do {
            let remoteContent = try AppRuntimeConfiguration.sanitizeRemote(downloadedContent)
            try await BlockingIO.run {
                var error: NSError?
                LibboxCheckConfig(remoteContent, &error)
                if let error {
                    throw error
                }
            }
            ProfileUpdateDiagnostics.record(source: mode.source, event: "configuration validation succeeded")
            var contentChanged = true
            do {
                let oldContent = try await readAsync()
                if oldContent == remoteContent {
                    contentChanged = false
                }
            } catch {}
            if contentChanged {
                try await writeAsync(remoteContent)
            }
            if contentChanged || responseETag != remoteETag {
                try await onProfileUpdated()
            }
            await MainActor.run {
                lastUpdated = Date()
                remoteETag = responseETag
            }
            try await ProfileManager.update(self)
            ProfileUpdateDiagnostics.record(
                source: mode.source,
                event: contentChanged ? "configuration saved" : "configuration unchanged"
            )
        } catch {
            ProfileUpdateDiagnostics.record(source: mode.source, event: "validation or save failed: \(error.localizedDescription)")
            throw error
        }
    }

    nonisolated func onProfileUpdated() async throws {
        if await SharedPreferences.selectedProfileID.get() == id {
            if let profile = try? await ExtensionProfile.load() {
                if await profile.status == .connected {
                    try await profile.reloadService()
                }
            }
        }
    }
}
