import Foundation

struct OddsEventInfo: Identifiable, Hashable {
    let id: String
    let homeTeam: String
    let awayTeam: String
    let homeCode: String
    let awayCode: String
    let commence: Date

    var matchupLabel: String { "\(awayCode) @ \(homeCode)" }

    var kickoffLabel: String {
        commence.formatted(date: .omitted, time: .shortened)
    }

    func involves(teamCode: String) -> Bool {
        let key = NFLScheduleService.normalizeTeam(teamCode)
        return homeCode == key || awayCode == key
    }
}

struct OddsPlayerProp: Identifiable, Hashable {
    let id: String
    let playerName: String
    let marketKey: String
    let marketLabel: String
    let line: Double?
    let overPrice: Int?
    let underPrice: Int?
    let bookmaker: String
    let eventId: String
    let matchupLabel: String
    let commence: Date

    var lineLabel: String {
        guard let line else {
            if let overPrice {
                return "Yes \(Self.formatAmerican(overPrice))"
            }
            return marketLabel
        }
        let pts = Self.trimPoint(line)
        if let overPrice, let underPrice {
            return "\(pts)  O \(Self.formatAmerican(overPrice)) / U \(Self.formatAmerican(underPrice))"
        }
        if let overPrice {
            return "O \(pts) (\(Self.formatAmerican(overPrice)))"
        }
        return "O/U \(pts)"
    }

    var shortLine: String {
        if let line { return Self.trimPoint(line) }
        if overPrice != nil { return "Yes" }
        return "—"
    }

    static func formatAmerican(_ price: Int) -> String {
        price > 0 ? "+\(price)" : "\(price)"
    }

    static func trimPoint(_ point: Double) -> String {
        if point.rounded() == point { return String(Int(point)) }
        return String(format: "%.1f", point)
    }

    static func label(forMarket key: String) -> String {
        switch key {
        case "player_pass_yds": return "Pass yds"
        case "player_pass_tds": return "Pass TDs"
        case "player_rush_yds": return "Rush yds"
        case "player_receptions": return "Receptions"
        case "player_reception_yds": return "Rec yds"
        case "player_anytime_td": return "Anytime TD"
        case "player_rush_tds": return "Rush TDs"
        case "player_reception_tds": return "Rec TDs"
        default:
            return key
                .replacingOccurrences(of: "player_", with: "")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    /// Preferred markets by fantasy position (first match wins for “primary”).
    static func preferredMarkets(for position: String) -> [String] {
        switch position.uppercased() {
        case "QB":
            return ["player_pass_yds", "player_pass_tds", "player_rush_yds", "player_anytime_td"]
        case "RB":
            return ["player_rush_yds", "player_receptions", "player_reception_yds", "player_anytime_td"]
        case "WR", "TE":
            return ["player_receptions", "player_reception_yds", "player_anytime_td", "player_rush_yds"]
        case "K":
            return ["player_anytime_td"]
        default:
            return ["player_anytime_td", "player_receptions", "player_rush_yds", "player_pass_yds"]
        }
    }
}

struct OddsRosterInsight: Identifiable, Hashable {
    var id: String { player.playerId }
    let player: RosterPlayer
    let primary: OddsPlayerProp?
    let props: [OddsPlayerProp]
    let matchupLabel: String?
}

/// Caches NFL player props (event-odds) and matches them onto roster players by name.
actor OddsIntelService {
    static let shared = OddsIntelService()

    private var events: [OddsEventInfo] = []
    private var props: [OddsPlayerProp] = []
    private var byPlayerFold: [String: [OddsPlayerProp]] = [:]
    private var loadedAt: Date?
    private var loadedEventIDs: Set<String> = []
    /// Roster NFL teams used for the last props fetch (league switch must refetch).
    private var loadedTeamSignature: String = ""

    private(set) var lastStatus: String?
    private(set) var lastRemaining: Int?
    private(set) var lastWasError = false

    var isConfigured: Bool { OddsAPIClient.hasAPIKey }
    var hasData: Bool { !props.isEmpty }
    var allEvents: [OddsEventInfo] { events.sorted { $0.commence < $1.commence } }
    var allProps: [OddsPlayerProp] {
        props.sorted {
            if $0.commence != $1.commence { return $0.commence < $1.commence }
            if $0.playerName != $1.playerName { return $0.playerName < $1.playerName }
            return $0.marketLabel < $1.marketLabel
        }
    }

    func reset() async {
        events = []
        props = []
        byPlayerFold = [:]
        loadedAt = nil
        loadedEventIDs = []
        loadedTeamSignature = ""
        lastStatus = nil
        lastRemaining = nil
        lastWasError = false
        await OddsAPIClient.shared.clearCache()
    }

    func invalidate() async {
        loadedAt = nil
        loadedEventIDs = []
        loadedTeamSignature = ""
        await OddsAPIClient.shared.clearCache()
    }

    /// Loads player props for the roster’s games.
    /// - Current / future weeks: live Odds API event props.
    /// - Historic weeks: historical event-odds snapshots (paid Odds API plans).
    func ensureLoaded(
        players: [RosterPlayer] = [],
        season: Int,
        week: Int,
        isHistoric: Bool,
        hasLiveGames: Bool = false
    ) async {
        let teamKeys = Set(
            players
                .map { NFLScheduleService.normalizeTeam($0.team) }
                .filter { !$0.isEmpty }
        )
        let teamSig = "\(season):w\(week):\(isHistoric ? "h" : "c"):" + teamKeys.sorted().joined(separator: ",")
        let maxAge: TimeInterval = hasLiveGames ? 60 : (isHistoric ? 86_400 : 3_600)
        if let loadedAt,
           Date().timeIntervalSince(loadedAt) < maxAge,
           !props.isEmpty,
           loadedTeamSignature == teamSig {
            return
        }
        guard OddsAPIClient.hasAPIKey else {
            lastStatus = "No Odds API key"
            lastWasError = false
            return
        }

        do {
            if isHistoric {
                try await loadHistoric(
                    players: players,
                    teamKeys: teamKeys,
                    season: season,
                    week: week,
                    teamSig: teamSig
                )
            } else {
                try await loadCurrent(
                    teamKeys: teamKeys,
                    teamSig: teamSig,
                    hasLiveGames: hasLiveGames
                )
            }
        } catch {
            lastWasError = true
            lastStatus = error.localizedDescription
        }
    }

    private func loadCurrent(
        teamKeys: Set<String>,
        teamSig: String,
        hasLiveGames: Bool
    ) async throws {
        let eventData = try await OddsAPIClient.shared.nflEvents()
        let parsedEvents = Self.parseEvents(eventData)
        events = parsedEvents

        var targetEvents = parsedEvents.filter { event in
            teamKeys.isEmpty
                || teamKeys.contains(event.homeCode)
                || teamKeys.contains(event.awayCode)
        }
        if targetEvents.isEmpty {
            targetEvents = Array(parsedEvents.sorted { $0.commence < $1.commence }.prefix(8))
        } else if targetEvents.count > 14 {
            targetEvents = Array(targetEvents.sorted { $0.commence < $1.commence }.prefix(14))
        }

        var collected: [OddsPlayerProp] = []
        var failed = 0
        for event in targetEvents {
            do {
                let data = try await OddsAPIClient.shared.eventPlayerProps(
                    eventId: event.id,
                    hasLiveGames: hasLiveGames
                )
                collected.append(contentsOf: Self.parseProps(data, event: event))
            } catch let error as OddsAPIError {
                if case .quota = error {
                    lastWasError = true
                    lastStatus = error.localizedDescription
                    lastRemaining = await OddsAPIClient.shared.lastRemaining
                    commit(collected: collected, events: targetEvents, teamSig: teamSig)
                    return
                }
                failed += 1
            } catch {
                failed += 1
            }
        }
        finishLoad(collected: collected, targetCount: targetEvents.count, failed: failed, teamSig: teamSig, events: targetEvents)
    }

    private func loadHistoric(
        players: [RosterPlayer],
        teamKeys: Set<String>,
        season: Int,
        week: Int,
        teamSig: String
    ) async throws {
        let schedule = await NFLScheduleService.teamGames(season: season, week: week)
        let rosterKickoffs: [Date] = players.compactMap { player in
            let key = NFLScheduleService.normalizeTeam(player.team)
            return schedule[key]?.kickoff ?? schedule[player.team.uppercased()]?.kickoff
        }
        let allKickoffs = schedule.values.map(\.kickoff)
        let kickoffs = rosterKickoffs.isEmpty ? allKickoffs : rosterKickoffs
        guard let windowStart = kickoffs.min(), let windowEnd = kickoffs.max() else {
            lastWasError = true
            lastStatus = "No NFL schedule for week \(week) — can’t load historic props."
            return
        }

        let snapshot = windowStart.addingTimeInterval(-3 * 3600)
        let commenceFrom = windowStart.addingTimeInterval(-36 * 3600)
        let commenceTo = windowEnd.addingTimeInterval(12 * 3600)

        let eventData = try await OddsAPIClient.shared.historicalEvents(
            snapshot: snapshot,
            commenceFrom: commenceFrom,
            commenceTo: commenceTo
        )
        let parsedEvents = Self.parseEvents(eventData)
        events = parsedEvents

        var targetEvents = parsedEvents.filter { event in
            teamKeys.isEmpty
                || teamKeys.contains(event.homeCode)
                || teamKeys.contains(event.awayCode)
        }
        if targetEvents.isEmpty {
            targetEvents = Array(parsedEvents.sorted { $0.commence < $1.commence }.prefix(8))
        } else if targetEvents.count > 8 {
            targetEvents = Array(targetEvents.sorted { $0.commence < $1.commence }.prefix(8))
        }

        var collected: [OddsPlayerProp] = []
        var failed = 0
        for event in targetEvents {
            let eventSnapshot = event.commence.addingTimeInterval(-2 * 3600)
            let useSnap = eventSnapshot > snapshot ? eventSnapshot : snapshot
            do {
                let data = try await OddsAPIClient.shared.historicalEventPlayerProps(
                    eventId: event.id,
                    snapshot: useSnap
                )
                collected.append(contentsOf: Self.parseProps(data, event: event))
            } catch let error as OddsAPIError {
                if case .quota = error {
                    lastWasError = true
                    lastStatus = error.localizedDescription
                    lastRemaining = await OddsAPIClient.shared.lastRemaining
                    commit(collected: collected, events: targetEvents, teamSig: teamSig)
                    return
                }
                if case .historicUnavailable = error {
                    throw error
                }
                failed += 1
            } catch {
                failed += 1
            }
        }
        finishLoad(collected: collected, targetCount: targetEvents.count, failed: failed, teamSig: teamSig, events: targetEvents)
    }

    private func finishLoad(
        collected: [OddsPlayerProp],
        targetCount: Int,
        failed: Int,
        teamSig: String,
        events targetEvents: [OddsEventInfo]
    ) {
        commit(collected: collected, events: targetEvents, teamSig: teamSig)
        lastRemaining = nil
        if collected.isEmpty {
            lastWasError = true
            lastStatus = failed > 0
                ? "No player props returned (\(failed) event fetches failed)."
                : "No player props available for these games yet."
        } else {
            lastWasError = false
            lastStatus = "Loaded \(collected.count) props across \(targetCount) games"
        }
    }

    private func commit(
        collected: [OddsPlayerProp],
        events targetEvents: [OddsEventInfo],
        teamSig: String
    ) {
        props = collected
        byPlayerFold = Dictionary(grouping: collected) { Self.foldName($0.playerName) }
        loadedEventIDs = Set(targetEvents.map(\.id))
        loadedTeamSignature = teamSig
        loadedAt = .now
    }

    func props(for player: RosterPlayer) async -> [OddsPlayerProp] {
        for name in await nameCandidates(for: player) {
            let matched = matchProps(name: name, position: player.position)
            if !matched.isEmpty { return matched }
        }
        return []
    }

    func props(forPlayerName name: String, position: String = "") -> [OddsPlayerProp] {
        matchProps(name: Self.normalizePersonName(name), position: position)
    }

    func rosterInsights(from players: [RosterPlayer], limit: Int = 24) async -> [OddsRosterInsight] {
        var rows: [OddsRosterInsight] = []
        for player in players.prefix(40) {
            guard player.gameLockState != "bye" else { continue }
            let matched = await props(for: player)
            let preferred = OddsPlayerProp.preferredMarkets(for: player.position)
            let primary = preferred.compactMap { key in matched.first { $0.marketKey == key } }.first
                ?? matched.first
            if primary == nil, matched.isEmpty { continue }
            rows.append(
                OddsRosterInsight(
                    player: player,
                    primary: primary,
                    props: matched,
                    matchupLabel: primary?.matchupLabel
                        ?? events.first(where: { $0.involves(teamCode: player.team) })?.matchupLabel
                )
            )
        }
        return Array(
            rows.sorted {
                ($0.primary?.line ?? -1) > ($1.primary?.line ?? -1)
            }
            .prefix(limit)
        )
    }

    /// Compact prop lines for agent context / chat tools.
    func contextLines(for players: [RosterPlayer], limit: Int = 20) async -> String {
        guard isConfigured else {
            return "PLAYER PROPS: (no Odds API key — add one in Settings → APIs)"
        }
        if let lastStatus, props.isEmpty, lastWasError {
            return "PLAYER PROPS: \(lastStatus)"
        }
        let insights = await rosterInsights(from: players, limit: limit)
        guard !insights.isEmpty else {
            return "PLAYER PROPS: (none matched for this roster — \(lastStatus ?? "ok"))"
        }
        var lines: [String] = [
            "PLAYER PROPS (use as secondary sit/start & short-term trade signal; injury + locks still win):"
        ]
        for row in insights {
            let inj = row.player.injuryStatus.map { " injury=\($0)" } ?? ""
            let match = row.matchupLabel.map { " \($0)" } ?? ""
            var bits: [String] = ["\(row.player.name) \(row.player.position)\(match)\(inj)"]
            let propsText = row.props.prefix(4).map { prop in
                "\(prop.marketLabel) \(prop.shortLine)"
            }.joined(separator: " · ")
            if !propsText.isEmpty {
                bits.append(propsText)
            }
            if let book = row.props.first?.bookmaker {
                bits.append("via \(book)")
            }
            lines.append("- " + bits.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    /// Tool text for specific player IDs / names.
    func propsToolText(for players: [RosterPlayer], limitPerPlayer: Int = 5) async -> String {
        guard isConfigured else {
            return "PLAYER PROPS: (no Odds API key — add one in Settings → APIs)"
        }
        if players.isEmpty {
            return "PLAYER PROPS: no players provided."
        }
        var lines: [String] = ["PLAYER PROPS:"]
        var any = false
        for player in players.prefix(12) {
            let matched = await props(for: player)
            if matched.isEmpty {
                lines.append("- \(player.name): (no props matched)")
                continue
            }
            any = true
            let inj = player.injuryStatus.map { " injury=\($0)" } ?? ""
            lines.append("- \(player.name) \(player.position) \(player.team)\(inj):")
            for prop in matched.prefix(limitPerPlayer) {
                lines.append("  \(prop.marketLabel): \(prop.lineLabel) (\(prop.bookmaker)) \(prop.matchupLabel)")
            }
        }
        if !any {
            lines.append("(no props matched — \(lastStatus ?? "ok"))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Matching

    private func nameCandidates(for player: RosterPlayer) async -> [String] {
        var names: [String] = []
        func add(_ raw: String?) {
            guard let raw else { return }
            let n = Self.normalizePersonName(raw)
            guard !n.isEmpty, !names.contains(n) else { return }
            names.append(n)
        }
        add(player.name)
        await PlayerIDCrosswalk.shared.ensureLoaded()
        if let link = await PlayerIDCrosswalk.shared.record(mflId: player.playerId) {
            add(link.name)
        }
        if let link = await PlayerIDCrosswalk.shared.record(sleeperId: player.playerId) {
            add(link.name)
        }
        if let link = await PlayerIDCrosswalk.shared.resolve(playerId: player.playerId) {
            add(link.name)
        }
        return names
    }

    private func matchProps(name: String, position: String) -> [OddsPlayerProp] {
        let normalized = Self.normalizePersonName(name)
        let fold = Self.foldName(normalized)
        if let exact = byPlayerFold[fold], !exact.isEmpty {
            return sortProps(exact, position: position)
        }
        let (first, last) = Self.splitName(normalized)
        let lastFold = Self.foldToken(last)
        guard !lastFold.isEmpty else { return [] }
        let firstFold = Self.foldToken(first)
        let fuzzy = props.filter { prop in
            let (pFirst, pLast) = Self.splitName(prop.playerName)
            guard Self.foldToken(pLast) == lastFold else { return false }
            if firstFold.isEmpty { return true }
            let pf = Self.foldToken(pFirst)
            return pf == firstFold
                || pf.hasPrefix(String(firstFold.prefix(1)))
                || firstFold.hasPrefix(String(pf.prefix(1)))
        }
        return sortProps(fuzzy, position: position)
    }

    private func sortProps(_ list: [OddsPlayerProp], position: String) -> [OddsPlayerProp] {
        let preferred = OddsPlayerProp.preferredMarkets(for: position)
        return list.sorted { a, b in
            let ai = preferred.firstIndex(of: a.marketKey) ?? 99
            let bi = preferred.firstIndex(of: b.marketKey) ?? 99
            if ai != bi { return ai < bi }
            return a.marketLabel < b.marketLabel
        }
    }

    // MARK: - Parse

    private static func parseEvents(_ data: Data) -> [OddsEventInfo] {
        let rows: [[String: Any]]
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            rows = arr
        } else if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = root["data"] as? [[String: Any]] {
            rows = arr
        } else {
            return []
        }
        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let home = row["home_team"] as? String,
                  let away = row["away_team"] as? String
            else { return nil }
            return OddsEventInfo(
                id: id,
                homeTeam: home,
                awayTeam: away,
                homeCode: code(for: home),
                awayCode: code(for: away),
                commence: parseDate(row["commence_time"]) ?? .now
            )
        }
    }

    private static func parseProps(_ data: Data, event: OddsEventInfo) -> [OddsPlayerProp] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        // Live event-odds is the event object; historical wraps it in `data`.
        let eventRoot = (root["data"] as? [String: Any]) ?? root
        let books = (eventRoot["bookmakers"] as? [[String: Any]]) ?? []
        guard let pick = preferredBook(books) else { return [] }
        let bookTitle = (pick["title"] as? String) ?? (pick["key"] as? String) ?? "Book"
        let markets = (pick["markets"] as? [[String: Any]]) ?? []

        var byKey: [String: OddsPlayerProp] = [:]
        for market in markets {
            let marketKey = (market["key"] as? String) ?? ""
            guard marketKey.hasPrefix("player_") else { continue }
            let outcomes = (market["outcomes"] as? [[String: Any]]) ?? []

            // Group Over/Under (or Yes) by player description.
            var buckets: [String: (line: Double?, over: Int?, under: Int?)] = [:]
            for o in outcomes {
                let playerName = ((o["description"] as? String) ?? (o["name"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !playerName.isEmpty,
                      playerName.lowercased() != "over",
                      playerName.lowercased() != "under"
                else { continue }

                let side = ((o["name"] as? String) ?? "").lowercased()
                let price = intValue(o["price"])
                let point = doubleValue(o["point"])
                var bucket = buckets[playerName] ?? (nil, nil, nil)
                if point != nil { bucket.line = point }
                if side == "over" || side == "yes" {
                    bucket.over = price
                } else if side == "under" || side == "no" {
                    bucket.under = price
                } else if marketKey == "player_anytime_td" {
                    // Some books list the player as `name` with no Over/Under.
                    bucket.over = price ?? bucket.over
                }
                buckets[playerName] = bucket
            }

            for (playerName, bucket) in buckets {
                let id = "\(event.id)|\(marketKey)|\(foldName(playerName))"
                byKey[id] = OddsPlayerProp(
                    id: id,
                    playerName: playerName,
                    marketKey: marketKey,
                    marketLabel: OddsPlayerProp.label(forMarket: marketKey),
                    line: bucket.line,
                    overPrice: bucket.over,
                    underPrice: bucket.under,
                    bookmaker: bookTitle,
                    eventId: event.id,
                    matchupLabel: event.matchupLabel,
                    commence: event.commence
                )
            }
        }
        return Array(byKey.values)
    }

    private static let preferredBookKeys = ["draftkings", "fanduel", "betmgm", "caesars", "williamhill_us"]

    private static func preferredBook(_ books: [[String: Any]]) -> [String: Any]? {
        for key in preferredBookKeys {
            if let hit = books.first(where: { ($0["key"] as? String) == key }) {
                return hit
            }
        }
        return books.first
    }

    private static func code(for fullName: String) -> String {
        let map: [String: String] = [
            "Arizona Cardinals": "ARI", "Atlanta Falcons": "ATL", "Baltimore Ravens": "BAL",
            "Buffalo Bills": "BUF", "Carolina Panthers": "CAR", "Chicago Bears": "CHI",
            "Cincinnati Bengals": "CIN", "Cleveland Browns": "CLE", "Dallas Cowboys": "DAL",
            "Denver Broncos": "DEN", "Detroit Lions": "DET", "Green Bay Packers": "GBP",
            "Houston Texans": "HOU", "Indianapolis Colts": "IND", "Jacksonville Jaguars": "JAC",
            "Kansas City Chiefs": "KCC", "Las Vegas Raiders": "LVR", "Los Angeles Chargers": "LAC",
            "Los Angeles Rams": "LAR", "Miami Dolphins": "MIA", "Minnesota Vikings": "MIN",
            "New England Patriots": "NEP", "New Orleans Saints": "NOS", "New York Giants": "NYG",
            "New York Jets": "NYJ", "Philadelphia Eagles": "PHI", "Pittsburgh Steelers": "PIT",
            "San Francisco 49ers": "SFO", "Seattle Seahawks": "SEA", "Tampa Bay Buccaneers": "TBB",
            "Tennessee Titans": "TEN", "Washington Commanders": "WAS",
        ]
        if let hit = map[fullName] {
            return NFLScheduleService.normalizeTeam(hit)
        }
        let last = fullName.split(separator: " ").last.map(String.init) ?? fullName
        return NFLScheduleService.normalizeTeam(String(last.prefix(3)).uppercased())
    }

    private static func parseDate(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }

    private static func foldName(_ name: String) -> String {
        let (first, last) = splitName(normalizePersonName(name))
        return "\(foldToken(last))|\(foldToken(first))"
    }

    /// MFL uses "Last,First"; Odds API uses "First Last". Also drop Jr/III.
    static func normalizePersonName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains(",") {
            let parts = s.split(separator: ",", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if parts.count == 2 {
                s = "\(parts[1]) \(parts[0])"
            }
        }
        let suffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv", "v"]
        var tokens = s
            .replacingOccurrences(of: ".", with: "")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        while let last = tokens.last, suffixes.contains(last.lowercased()) {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }

    private static func splitName(_ name: String) -> (String, String) {
        let normalized = normalizePersonName(name)
        let suffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv", "v"]
        var parts = normalized
            .replacingOccurrences(of: ".", with: "")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        while let last = parts.last, suffixes.contains(last.lowercased()) {
            parts.removeLast()
        }
        guard let last = parts.last else { return ("", "") }
        let first = parts.dropLast().joined(separator: " ")
        return (first, last)
    }

    private static func foldToken(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d.rounded()) }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }
}
