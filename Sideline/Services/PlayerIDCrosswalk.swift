import Foundation

/// One row from DynastyProcess `db_playerids` — the industry standard fantasy ID crosswalk.
struct PlayerIDRecord: Hashable, Sendable {
    var mflId: String?
    var sleeperId: String?
    var fantasyProsId: String?
    var name: String
    var position: String
    var team: String
}

/// Shared MFL ↔ Sleeper ↔ FantasyPros identity map (DynastyProcess / nflverse).
///
/// Name matching alone is fragile across hosts. This table is the durable join key so
/// Sleeper leagues get the same FantasyPros ranks/projections (and optional MFL research)
/// that MFL leagues already enjoy via native MFL ids.
actor PlayerIDCrosswalk {
    static let shared = PlayerIDCrosswalk()

    private static let remoteURL = URL(
        string: "https://raw.githubusercontent.com/dynastyprocess/data/master/files/db_playerids.csv"
    )!

    private var byMFL: [String: PlayerIDRecord] = [:]
    private var bySleeper: [String: PlayerIDRecord] = [:]
    private var byFantasyPros: [String: PlayerIDRecord] = [:]
    private var loadedAt: Date?
    private let maxAge: TimeInterval = 86_400 * 7

    private(set) var lastStatus: String?
    var count: Int { bySleeper.count }

    private var diskURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sideline-db-playerids.csv")
    }

    func ensureLoaded() async {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < maxAge, !bySleeper.isEmpty {
            lastStatus = "\(bySleeper.count) id links cached"
            return
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: diskURL.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < maxAge,
           let data = try? Data(contentsOf: diskURL),
           !data.isEmpty {
            ingest(data)
            if !bySleeper.isEmpty {
                lastStatus = "\(bySleeper.count) id links (disk)"
                return
            }
        }

        do {
            var request = URLRequest(url: Self.remoteURL)
            request.timeoutInterval = 60
            request.setValue("Sideline/1.0 (com.cpf32.sideline; iOS)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                lastStatus = "Player ID crosswalk download failed"
                return
            }
            ingest(data)
            if !bySleeper.isEmpty {
                try? data.write(to: diskURL, options: .atomic)
                lastStatus = "\(bySleeper.count) id links loaded"
            } else {
                lastStatus = "Player ID crosswalk parsed empty"
            }
        } catch {
            lastStatus = "Player ID crosswalk failed: \(error.localizedDescription)"
        }
    }

    func record(mflId: String) -> PlayerIDRecord? {
        let raw = mflId.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hit = byMFL[raw] { return hit }
        return byMFL[MFLNameResolver.normalizePlayerId(raw)]
    }

    func record(sleeperId: String) -> PlayerIDRecord? {
        bySleeper[sleeperId.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    func record(fantasyProsId: String) -> PlayerIDRecord? {
        byFantasyPros[fantasyProsId.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// Resolve any host id → full crosswalk row.
    func resolve(playerId: String, providerHint: String? = nil) -> PlayerIDRecord? {
        let id = playerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        if providerHint == "sleeper", let hit = bySleeper[id] { return hit }
        if providerHint == "mfl", let hit = record(mflId: id) { return hit }
        if let hit = bySleeper[id] { return hit }
        if let hit = record(mflId: id) { return hit }
        if let hit = byFantasyPros[id] { return hit }
        return nil
    }

    // MARK: - CSV

    private func ingest(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        var byMFL: [String: PlayerIDRecord] = [:]
        var bySleeper: [String: PlayerIDRecord] = [:]
        var byFP: [String: PlayerIDRecord] = [:]

        var headerIndex: [String: Int] = [:]
        var isHeader = true
        for line in text.split(whereSeparator: \.isNewline) {
            let cols = Self.parseCSVLine(String(line))
            if isHeader {
                for (i, name) in cols.enumerated() {
                    headerIndex[name.lowercased()] = i
                }
                isHeader = false
                continue
            }
            guard !cols.isEmpty else { continue }

            func col(_ name: String) -> String? {
                guard let i = headerIndex[name], i < cols.count else { return nil }
                let v = cols[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if v.isEmpty || v.uppercased() == "NA" || v.lowercased() == "null" { return nil }
                return v
            }

            let mfl = col("mfl_id")
            let sleeper = col("sleeper_id")
            let fp = col("fantasypros_id")
            guard mfl != nil || sleeper != nil || fp != nil else { continue }

            let record = PlayerIDRecord(
                mflId: mfl,
                sleeperId: sleeper,
                fantasyProsId: fp,
                name: col("name") ?? "",
                position: col("position") ?? "",
                team: col("team") ?? ""
            )
            if let mfl {
                byMFL[mfl] = record
                byMFL[MFLNameResolver.normalizePlayerId(mfl)] = record
            }
            if let sleeper { bySleeper[sleeper] = record }
            if let fp { byFP[fp] = record }
        }

        guard !bySleeper.isEmpty || !byMFL.isEmpty else { return }
        self.byMFL = byMFL
        self.bySleeper = bySleeper
        self.byFantasyPros = byFP
        self.loadedAt = .now
    }

    /// Minimal CSV splitter (handles quoted fields).
    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for ch in line {
            if ch == "\"" {
                inQuotes.toggle()
                continue
            }
            if ch == ",", !inQuotes {
                fields.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        fields.append(current)
        return fields
    }
}
