import ApplicationLibrary
import Library
import SwiftUI

struct MainView: View {
    private static let configurationURL = "https://www.sanzhihema.com/sing.conf"

    @EnvironmentObject private var environments: ExtensionEnvironments
    @StateObject private var automaticProfile = NewProfileViewModel()

    var body: some View {
        NavigationStackCompat {
            DashboardView()
        }
        .alert($automaticProfile.alert)
        .onAppear {
            environments.ensureDefaultProfile = { [self] in await ensureConfiguration() }
            environments.postReload()
        }
    }

    /// Fetches/creates the bundled "Network Tools" subscription if it doesn't exist yet,
    /// or re-sanitizes it if its content drifted. Called on demand from the Start button
    /// (via `environments.ensureDefaultProfile`) rather than eagerly on launch, so a cold
    /// start with no network access yet doesn't surface a spurious download failure before
    /// the user has even installed the network extension.
    private func ensureConfiguration() async {
        do {
            let profiles = try await ProfileManager.list()
            if let profile = profiles.first(where: {
                $0.type == .remote && $0.remoteURL == Self.configurationURL
            }) {
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
                let storedContent = try await profile.readAsync()
                let sanitizedContent = try AppRuntimeConfiguration.sanitizeRemote(storedContent)
                if sanitizedContent != storedContent {
                    try await profile.writeAsync(sanitizedContent)
                    try await profile.onProfileUpdated()
                }
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
            await automaticProfile.createProfile(
                environments: environments,
                onSuccess: { profile in
                    await SharedPreferences.selectedProfileID.set(profile.mustID)
                }
            )
            await MainActor.run {
                environments.postReload()
            }
        } catch {}
    }
}
