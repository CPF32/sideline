import Foundation

/// Structured player profile for the detail sheet (MFL + Sleeper enrichment).
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
    var newsHeadlines: [String]
    // Sleeper enrichment
    var college: String? = nil
    var number: String? = nil
    var status: String? = nil
    var yearsExp: String? = nil
    var depthChart: String? = nil
    var sleeperPlayerId: String? = nil
}
