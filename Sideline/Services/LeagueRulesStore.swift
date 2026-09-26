import Foundation

/// Season-fixed league roster rules, stored per linked league.
///
/// Starter slots / flex / IR counts do not change mid-season, so we fetch once and reuse.
enum LeagueRulesStore {
    private static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sideline-league-rules", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func load(linked: LinkedFranchise) -> LeagueRules? {
        load(Payload.self, key: key(linked))?.rules
    }

    /// Persist only when starter slots are present — empty rules are not reusable.
    static func save(linked: LinkedFranchise, rules: LeagueRules) {
        guard !rules.starterSlots.isEmpty else { return }
        save(Payload(season: linked.season, rules: rules), key: key(linked))
    }

    /// Prefer a prior season cache; otherwise use `fresh` and persist it.
    static func resolve(linked: LinkedFranchise, fresh: LeagueRules) -> LeagueRules {
        if let cached = load(linked: linked), !cached.starterSlots.isEmpty {
            return cached
        }
        if !fresh.starterSlots.isEmpty {
            save(linked: linked, rules: fresh)
        }
        return fresh
    }

    static func clear(linked: LinkedFranchise) {
        remove(key(linked))
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

    private static func key(_ linked: LinkedFranchise) -> String {
        // v2: ESPN slot-id order + proper flex (`RB/WR/TE`); invalidate v1 alpha-sorted caches.
        "rules-v2-\(sanitize(linked.providerRaw))-\(sanitize(linked.leagueId))-\(linked.season)"
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

    private struct Payload: Codable {
        var season: Int
        var rules: LeagueRules
    }
}
