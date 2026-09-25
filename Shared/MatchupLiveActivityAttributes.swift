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
        /// Unix seconds of the next backend sync; drives the countdown.
        var nextSyncAt: Double? = nil
        /// Mutable so the Lock Screen can cycle leagues without restarting the activity.
        var leagueName: String = ""
        var myTeamName: String = ""
        var providerLabel: String = ""
        var leagueLinkId: String = ""
        /// When > 1, the Live Activity shows a cycle control.
        var leagueCount: Int = 1
    }

    /// Static shell — prefer ContentState fields for anything that can change mid-activity.
    var leagueName: String
    var myTeamName: String
    var providerLabel: String
}

enum MatchupLiveSyncSchedule {
    /// Matches the backend poll cadence (wrangler.toml / scores.ts).
    static let intervalSeconds: TimeInterval = 5 * 60

    /// Target time for the next refresh: always ~5 minutes after `date`.
    /// (Not clock-aligned — avoids a short leftover like 3:50 after a late push.)
    static func nextSyncAt(after date: Date = Date()) -> Double {
        date.timeIntervalSince1970 + intervalSeconds
    }
}
