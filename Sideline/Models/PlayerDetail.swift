import Foundation

/// Structured MFL playerProfile + related feeds for the player detail sheet.
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
}
