import Foundation

/// Shared HTTP / blob cache for Sideline network loads.
///
/// Policies:
/// - `.standard` — 1 hour (rankings, projections, rosters metadata, etc.)
/// - `.live` — 1 minute (matchups / live scoring / schedule while games are on)
/// - `.liveAware(hasLiveGames:)` — 1 minute if any related game is live, else 1 hour
/// - `.day` / `.week` — catalogs and ID crosswalks
/// - `.permanent` — fantasy league/franchise schedules (fixed for the season; never recheck)
actor DataCache {
    static let shared = DataCache()

    enum Policy: Sendable {
        case standard
        case live
        case liveAware(hasLiveGames: Bool)
        case day
        case week
        case permanent

        var ttl: TimeInterval {
            switch self {
            case .standard: return 3_600
            case .live: return 60
            case .liveAware(let live): return live ? 60 : 3_600
            case .day: return 86_400
            case .week: return 86_400 * 7
            case .permanent: return .infinity
            }
        }
    }

    /// True when any rostered player is in a started NFL game.
    static func hasLiveGames(in players: [RosterPlayer]) -> Bool {
        players.contains { $0.gameLockState == "started" }
    }

    static func hasLiveGames(in snapshot: TeamSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return hasLiveGames(in: snapshot.starters)
            || hasLiveGames(in: snapshot.bench)
            || hasLiveGames(in: snapshot.ir)
            || hasLiveGames(in: snapshot.taxi)
    }

    private struct Entry {
        var data: Data
        var storedAt: Date
    }

    private var memory: [String: Entry] = [:]
    private let diskFolder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sideline-datacache", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    // MARK: - Public API

    func get(_ key: String, policy: Policy) -> Data? {
        let ttl = policy.ttl
        if let hit = memory[key], isFresh(hit.storedAt, ttl: ttl) {
            return hit.data
        }
        if let disk = readDisk(key), isFresh(disk.storedAt, ttl: ttl) {
            memory[key] = disk
            return disk.data
        }
        return nil
    }

    private func isFresh(_ storedAt: Date, ttl: TimeInterval) -> Bool {
        if ttl.isInfinite { return true }
        return Date().timeIntervalSince(storedAt) < ttl
    }

    func age(of key: String) -> TimeInterval? {
        if let hit = memory[key] {
            return Date().timeIntervalSince(hit.storedAt)
        }
        if let disk = readDisk(key) {
            memory[key] = disk
            return Date().timeIntervalSince(disk.storedAt)
        }
        return nil
    }

    func set(_ data: Data, for key: String, persistToDisk: Bool = false) {
        let entry = Entry(data: data, storedAt: .now)
        memory[key] = entry
        if persistToDisk {
            writeDisk(key, entry: entry)
        }
    }

    /// Return cached data if fresh; otherwise run `fetch`, store, and return.
    func data(
        key: String,
        policy: Policy,
        persistToDisk: Bool = false,
        fetch: @Sendable () async throws -> Data
    ) async throws -> Data {
        if let hit = get(key, policy: policy) {
            return hit
        }
        let fresh = try await fetch()
        set(fresh, for: key, persistToDisk: persistToDisk)
        return fresh
    }

    func remove(_ key: String) {
        memory.removeValue(forKey: key)
        let url = diskURL(for: key)
        try? FileManager.default.removeItem(at: url)
    }

    func removeAll(matchingPrefix prefix: String) {
        for key in memory.keys where key.hasPrefix(prefix) {
            memory.removeValue(forKey: key)
        }
        guard let files = try? FileManager.default.contentsOfDirectory(at: diskFolder, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.lastPathComponent.hasPrefix(sanitize(prefix)) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func clearAll() {
        memory.removeAll()
        if let files = try? FileManager.default.contentsOfDirectory(at: diskFolder, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Disk

    private func diskURL(for key: String) -> URL {
        diskFolder.appendingPathComponent(sanitize(key) + ".cache")
    }

    private func sanitize(_ key: String) -> String {
        key
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "?", with: "_")
            .replacingOccurrences(of: "&", with: "_")
            .replacingOccurrences(of: "=", with: "_")
    }

    private func readDisk(_ key: String) -> Entry? {
        let url = diskURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date
        else { return nil }
        return Entry(data: data, storedAt: modified)
    }

    private func writeDisk(_ key: String, entry: Entry) {
        let url = diskURL(for: key)
        try? entry.data.write(to: url, options: .atomic)
    }
}
