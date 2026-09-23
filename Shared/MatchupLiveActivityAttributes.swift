import Foundation
import ActivityKit

/// Shared Live Activity attributes for in-progress fantasy matchups.
struct MatchupLiveAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var myScore: Double
        var oppScore: Double
        var opponentName: String
        var week: Int
        var statusLine: String
        var playerLines: [String]
        /// Unix seconds — number in APNs JSON for Codable interop with the push backend.
        var lastUpdated: Double
        /// Unix seconds of the next backend sync; drives the countdown. Nil when
        /// no push backend is configured.
        var nextSyncAt: Double? = nil
    }

    var leagueName: String
    var myTeamName: String
    var providerLabel: String
}
