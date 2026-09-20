import SwiftUI
import AuthenticationServices

struct WelcomeView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            SidelineBackground()
            VStack(spacing: 28) {
                Spacer()
                VStack(spacing: 8) {
                    Text(BrandTheme.appName.uppercased())
                        .font(BrandTheme.display(44, weight: .heavy))
                        .foregroundStyle(BrandTheme.ink)
                        .tracking(2)
                    Text("Your fantasy GM on the sideline.")
                        .font(BrandTheme.body(16))
                        .foregroundStyle(BrandTheme.muted)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)

                VStack(spacing: 12) {
                    SignInWithAppleButtonView { result in
                        appState.auth.handleSignIn(result)
                    }

                    Button {
                        appState.auth.continueLocally()
                    } label: {
                        Text("Continue")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Text("Simulator tip: Apple’s sheet often won’t finish without a paid Team + capability. Tap Continue to enter the app.")
                        .font(BrandTheme.body(12))
                        .foregroundStyle(BrandTheme.muted)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)

                if let error = appState.auth.errorMessage {
                    Text(error)
                        .font(BrandTheme.body(13))
                        .foregroundStyle(BrandTheme.danger)
                        .padding(.horizontal, 32)
                        .multilineTextAlignment(.center)
                }

                Spacer()
            }
        }
    }
}
