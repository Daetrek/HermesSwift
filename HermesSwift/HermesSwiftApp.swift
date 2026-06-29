import SwiftUI

@main
struct HermesSwiftApp: App {
    @StateObject private var settings = AppSettingsStore()
    @StateObject private var sessionStore = SessionStore()
    @StateObject private var sessionOrganization = SessionOrganizationStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(sessionStore)
                .environmentObject(sessionOrganization)
                .preferredColorScheme(.dark)
        }
    }
}
