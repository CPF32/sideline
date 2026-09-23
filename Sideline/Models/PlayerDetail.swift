import Foundation

/// Structured player note (FantasyPros news wire — short body + optional link, not longform articles).
struct PlayerNewsItem: Identifiable, Hashable {
    var id: String
    var title: String
    var body: String
    var linkURL: URL?
    var source: String
}

/// Structured player profile for the detail sheet (MFL + Sleeper + FantasyPros).
struct PlayerDetail: Identifiable, Hashable {
    var id: String { playerId }
    let playerId: String
    var name: String?
    var age: String?
    var dob: String?
    var height: String?
    var weight: String?
    var adp: String?
    var mflRank: String?
    var topAddsPct: String?
    var injury: String?
    /// Legacy compact lines for agents — prefer `newsItems` in UI.
    var newsHeadlines: [String]
    var newsItems: [PlayerNewsItem] = []
    // Sleeper enrichment
    var college: String? = nil
    var number: String? = nil
    var status: String? = nil
    var yearsExp: String? = nil
    var depthChart: String? = nil
    var sleeperPlayerId: String? = nil
    // FantasyPros enrichment
    var fpRankECR: String? = nil
    var fpPosRank: String? = nil
    var fpTier: String? = nil
    var fpRosRank: String? = nil
    var fpRosPosRank: String? = nil
    var fpProjection: String? = nil
}
