import Foundation
import GRDB
import Libbox

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
    nonisolated func updateRemoteProfile() async throws {
        if type != .remote {
            return
        }
        let url = remoteURL
        let result = try await HTTPClient.getStringConditionalAsync(url, etag: remoteETag)
        if case let .notModified(responseETag) = result {
            await MainActor.run {
                lastUpdated = Date()
                if let responseETag {
                    remoteETag = responseETag
                }
            }
            try await ProfileManager.update(self)
            return
        }
        guard case let .modified(downloadedContent, responseETag) = result else {
            return
        }
        let remoteContent = try AppRuntimeConfiguration.sanitizeRemote(downloadedContent)
        try await BlockingIO.run {
            var error: NSError?
            LibboxCheckConfig(remoteContent, &error)
            if let error {
                throw error
            }
        }
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
