import Foundation

/// Registers Live Activity push tokens with the Sideline live backend.
enum LiveActivityPushClient {
    /// Production Worker (dev + App Store). Override only via UserDefaults for local debugging.
    static let defaultBackendURL = "https://sideline-live.chrisfarish32.workers.dev"
    static let defaultRegisterSecret = "33dd2db8266c274b24999dc828b58a93813e2d6afeeffecf"

    static let backendURLKey = "sideline.liveActivity.backendURL"
    static let registerSecretKey = "sideline.liveActivity.registerSecret"

    static var backendURL: String {
        let stored = UserDefaults.standard.string(forKey: backendURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultBackendURL : stored
    }

    static var registerSecret: String {
        let stored = UserDefaults.standard.string(forKey: registerSecretKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultRegisterSecret : stored
    }

    static var isConfigured: Bool {
        let url = backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = registerSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.hasPrefix("http") && secret.count >= 8
    }

    struct RegisterPayload: Encodable {
        let activityId: String
        let pushToken: String
        let provider: String
        let leagueId: String
        let franchiseId: String
        let week: Int
        let season: Int
        let host: String?
        let mflCookie: String?
        let leagueName: String
        let myTeamName: String
        let providerLabel: String
        let opponentName: String?
        let playerNames: [String: String]?
        let starterIds: [String]?
        /// "sandbox" for Xcode/dev installs; "production" for TestFlight / App Store.
        let apnsEnvironment: String
    }

    /// Matches the APNs environment Apple issued this install’s push token for.
    static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    static func register(_ payload: RegisterPayload) async {
        guard isConfigured,
              let base = URL(string: backendURL.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        let url = base.appending(path: "v1/live-activity/register")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(registerSecret, forHTTPHeaderField: "X-Sideline-Key")
        request.httpBody = try? JSONEncoder().encode(payload)
        _ = try? await URLSession.shared.data(for: request)
    }

    static func unregister(activityId: String) async {
        guard isConfigured,
              let base = URL(string: backendURL.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        let url = base.appending(path: "v1/live-activity/\(activityId)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        request.setValue(registerSecret, forHTTPHeaderField: "X-Sideline-Key")
        _ = try? await URLSession.shared.data(for: request)
    }
}
