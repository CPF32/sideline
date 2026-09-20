import Foundation
import AuthenticationServices
import SwiftUI

@MainActor
final class AppleAuthService: ObservableObject {
    @Published private(set) var isSignedIn: Bool = false
    @Published private(set) var displayName: String = ""
    @Published var errorMessage: String?

    init() {
        let id = KeychainStore.get(.appleUserID)
        isSignedIn = id != nil
        displayName = KeychainStore.get(.appleDisplayName) ?? ""
    }

    /// Local device identity — works without Apple Developer Sign in with Apple provisioning.
    func continueLocally(as name: String = "Manager") {
        let userID = KeychainStore.get(.appleUserID) ?? "local.\(UUID().uuidString)"
        KeychainStore.set(userID, for: .appleUserID)
        KeychainStore.set(name, for: .appleDisplayName)
        displayName = name
        isSignedIn = true
        errorMessage = nil
    }

    /// Fixed identity for App Store screenshot captures.
    func applyScreenshotDemo() {
        KeychainStore.set("screenshot-demo-user", for: .appleUserID)
        KeychainStore.set("Chris", for: .appleDisplayName)
        displayName = "Chris"
        isSignedIn = true
        errorMessage = nil
    }

    func handleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = "Apple Sign In returned an unexpected credential."
                return
            }
            let userID = credential.user
            KeychainStore.set(userID, for: .appleUserID)
            if let fullName = credential.fullName {
                let composed = PersonNameComponentsFormatter().string(from: fullName)
                if !composed.trimmingCharacters(in: .whitespaces).isEmpty {
                    KeychainStore.set(composed, for: .appleDisplayName)
                    displayName = composed
                }
            }
            if displayName.isEmpty {
                displayName = KeychainStore.get(.appleDisplayName) ?? "Manager"
            }
            isSignedIn = true
            errorMessage = nil
        case .failure(let error):
            let ns = error as NSError
            if ns.domain == ASAuthorizationError.errorDomain {
                switch ASAuthorizationError.Code(rawValue: ns.code) {
                case .canceled:
                    return
                case .unknown, .failed:
                    // Common on Simulator / local codesign without a Team + capability.
                    errorMessage = "Apple Sign In didn’t finish. Use Continue below (common on Simulator), or run from Xcode with your Team and Sign in with Apple capability."
                    return
                case .invalidResponse, .notHandled, .notInteractive:
                    errorMessage = "Apple Sign In couldn’t complete (\(ns.code)). Use Continue below to keep going."
                    return
                default:
                    break
                }
            }
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        KeychainStore.delete(.appleUserID)
        KeychainStore.delete(.appleDisplayName)
        isSignedIn = false
        displayName = ""
    }
}

struct SignInWithAppleButtonView: View {
    var onCompletion: (Result<ASAuthorization, Error>) -> Void

    var body: some View {
        SignInWithAppleButton(.signIn, onRequest: { request in
            request.requestedScopes = [.fullName, .email]
        }, onCompletion: onCompletion)
        .signInWithAppleButtonStyle(.black)
        .frame(height: BrandTheme.space(48))
        .clipShape(RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous))
    }
}
