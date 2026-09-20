import SwiftUI
import SwiftData

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        // Observe auth directly — nested ObservableObject changes don't refresh AppState alone.
        AuthGate(auth: appState.auth)
            .environmentObject(appState)
            .onAppear {
                appState.attach(context: modelContext)
                ScreenshotDemo.applyIfNeeded(appState: appState, context: modelContext)
            }
    }
}

private struct AuthGate: View {
    @ObservedObject var auth: AppleAuthService
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if auth.isSignedIn || ScreenshotDemo.isEnabled {
                MainTabView()
            } else {
                WelcomeView()
            }
        }
    }
}
