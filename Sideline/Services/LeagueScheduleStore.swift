import Foundation

/// Season-fixed fantasy schedules, stored per linked franchise / league.
///
/// League pairings and a franchise's opponent list do not change mid-season, so we
/// fetch once and never recheck — only filter locally by the current NFL week.
enum LeagueScheduleStore {
    private static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sideline-league-schedules", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    // MARK: - Franchise upcoming (Team tab strip)

    static func loadFranchiseSchedule(linked: LinkedFranchise) -> [UpcomingMatchupPreview]? {
        load(FranchisePayload.self, key: franchiseKey(linked))?.rows
    }

    static func saveFranchiseSchedule(linked: LinkedFranchise, rows: [UpcomingMatchupPreview]) {
        guard !rows.isEmpty else { return }
        save(FranchisePayload(season: linked.season, rows: rows), key: franchiseKey(linked))
    }

    /// Rows after `afterWeek` (typically the live NFL week), capped for the UI strip.
    static func upcoming(
        linked: LinkedFranchise,
        afterWeek: Int,
        limit: Int = 4
    ) -> [UpcomingMatchupPreview]? {
        guard let all = loadFranchiseSchedule(linked: linked) else { return nil }
        return Array(
            all
                .filter { $0.week > afterWeek }
                .sorted { $0.week < $1.week }
                .prefix(limit)
        )
    }

    // MARK: - League-wide schedule blob (MFL / ESPN pairings)

    static func loadLeagueScheduleData(linked: LinkedFranchise) -> Data? {
        load(LeaguePayload.self, key: leagueKey(linked))?.data
    }

    static func saveLeagueScheduleData(linked: LinkedFranchise, data: Data) {
        guard !data.isEmpty else { return }
        save(LeaguePayload(season: linked.season, data: data), key: leagueKey(linked))
    }

    // MARK: - Lifecycle

    static func clear(linked: LinkedFranchise) {
        remove(franchiseKey(linked))
        remove(leagueKey(linked))
    }

    static func clearAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Keys / IO

    private static func franchiseKey(_ linked: LinkedFranchise) -> String {
        "franchise-\(sanitize(linked.id))-\(linked.season)"
    }

    private static func leagueKey(_ linked: LinkedFranchise) -> String {
        "league-\(sanitize(linked.providerRaw))-\(sanitize(linked.leagueId))-\(linked.season)"
    }

    private static func sanitize(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "|", with: "_")
    }

    private static func url(for key: String) -> URL {
        folder.appendingPathComponent(key + ".json")
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        let path = url(for: key)
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url(for: key), options: .atomic)
    }

    private static func remove(_ key: String) {
        try? FileManager.default.removeItem(at: url(for: key))
    }

    private struct FranchisePayload: Codable {
        var season: Int
        var rows: [UpcomingMatchupPreview]
    }

    private struct LeaguePayload: Codable {
        var season: Int
        var data: Data
    }
}
