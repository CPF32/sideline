import SwiftUI
import SwiftData

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    /// Screenshot runs seed async — hold the tab UI until demo data is ready.
    @State private var isScreenshotReady = !ScreenshotDemo.isEnabled

    var body: some View {
        // Observe auth directly — nested ObservableObject changes don't refresh AppState alone.
        Group {
            if ScreenshotDemo.isEnabled && !isScreenshotReady {
                ZStack { SidelineBackground() }
            } else {
                AuthGate(auth: appState.auth)
                    .environmentObject(appState)
            }
        }
        .onAppear {
            appState.attach(context: modelContext)
            Task {
                await ScreenshotDemo.applyIfNeeded(appState: appState, context: modelContext)
                isScreenshotReady = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                appState.persistUserPreferences()
            }
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
