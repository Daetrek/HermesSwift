import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @State private var path: [HermesSession] = []

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                TerminalTheme.background.ignoresSafeArea()
                if settings.apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ConnectionView()
                } else {
                    SessionListView(path: $path)
                }
            }
        }
        .tint(TerminalTheme.text)
        .foregroundColor(TerminalTheme.text)
        .background(TerminalTheme.background)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}
