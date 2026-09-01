import ApplicationLibrary
import Library
import SwiftUI

struct MainView: View {
    private static var configurationURL: String {
        try! AuthenticatedConfigurationURL.make().absoluteString
    }

    @EnvironmentObject private var environments: ExtensionEnvironments
    @StateObject private var automaticProfile = NewProfileViewModel()

    var body: some View {
        NavigationStackCompat {
            DashboardView()
        }
        .alert($automaticProfile.alert)
        .onAppear {
            environments.ensureDefaultProfile = { [self] in try await ensureConfiguration() }
            environments.refreshDefaultProfile = { [self] in try await refreshConfiguration() }
            environments.postReload()
        }
    }

    /// Fetches/creates the bundled "Network Tools" subscription if it doesn't exist yet,
    /// or re-sanitizes it if its content drifted. Called on demand from the Start button
    /// (via `environments.ensureDefaultProfile`) rather than eagerly on launch, so a cold
    /// start with no network access yet doesn't surface a spurious download failure before
    /// the user has even installed the network extension.
    private func ensureConfiguration() async throws {
        let profiles = try await ProfileManager.list()
        if let profile = profiles.first(where: {
            guard $0.type == .remote, let remoteURL = $0.remoteURL,
                  let components = URLComponents(string: remoteURL)
            else { return false }
            return components.host == "www.sanzhihema.com" && components.path == "/sing.conf"
        }) {
            if profile.remoteURL != Self.configurationURL {
                profile.remoteURL = Self.configurationURL
                try await ProfileManager.update(profile)
            }
            let selectedProfileID = await SharedPreferences.selectedProfileID.get()
            if !profiles.contains(where: { $0.id == selectedProfileID }) {
                await SharedPreferences.selectedProfileID.set(profile.mustID)
            }
            if !profile.autoUpdate || profile.autoUpdateInterval != 10 {
                profile.autoUpdate = true
                profile.autoUpdateInterval = 10
                try await ProfileManager.update(profile)
                try UIProfileUpdateTask.configure()
            }
            let storedContent: String
            do {
                storedContent = try await profile.readAsync()
            } catch let error where Profile.shouldRedownloadMissingRemoteContent(after: error) {
                ProfileUpdateDiagnostics.record(
                    source: .initial,
                    event: "profile record exists but local sing.conf is missing; redownloading"
                )
                try await profile.updateRemoteProfile(mode: .initial)
                environments.emptyProfiles = false
                await MainActor.run { environments.postReload() }
                return
            }
            ProfileUpdateDiagnostics.record(
                source: .local,
                event: "using local sing.conf (\(storedContent.utf8.count) bytes)"
            )
            let sanitizedContent = try AppRuntimeConfiguration.sanitizeRemote(storedContent)
            if sanitizedContent != storedContent {
                try await profile.writeAsync(sanitizedContent)
                try await profile.onProfileUpdated()
            }
            environments.emptyProfiles = false
            await MainActor.run { environments.postReload() }
            return
        }
        await MainActor.run {
            automaticProfile.profileName = "Network Tools"
            automaticProfile.profileType = .remote
            automaticProfile.remotePath = Self.configurationURL
            automaticProfile.autoUpdate = true
            automaticProfile.autoUpdateInterval = 10
        }
        ProfileUpdateDiagnostics.record(source: .initial, event: "sing.conf does not exist; initial download started")
        await automaticProfile.createProfile(
            environments: environments,
            onSuccess: { profile in
                await SharedPreferences.selectedProfileID.set(profile.mustID)
            },
            presentsFailureAlert: false
        )
        if let error = automaticProfile.lastCreationError {
            ProfileUpdateDiagnostics.record(source: .initial, event: "initial download failed: \(error.localizedDescription)")
            throw error
        }
        ProfileUpdateDiagnostics.record(source: .initial, event: "initial download, validation, and save succeeded")
        environments.emptyProfiles = false
        await MainActor.run {
            environments.postReload()
        }
    }

    private func refreshConfiguration() async throws {
        let profiles = try await ProfileManager.list()
        guard let profile = profiles.first(where: {
            guard $0.type == .remote, let remoteURL = $0.remoteURL,
                  let components = URLComponents(string: remoteURL)
            else { return false }
            return components.host == "www.sanzhihema.com" && components.path == "/sing.conf"
        }) else {
            throw NSError(domain: "SFI.Configuration", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Local sing.conf profile does not exist; tap Start once to download it.",
            ])
        }
        profile.remoteURL = Self.configurationURL
        try await ProfileManager.update(profile)
        try await profile.updateRemoteProfile(mode: .forced)
        environments.profileUpdate.send()
    }
}
