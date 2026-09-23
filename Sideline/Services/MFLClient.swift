import Foundation

enum MFLError: LocalizedError {
    case missingCredentials
    case loginFailed(String)
    case http(Int, String)
    case rateLimited
    case decode(String)
    case notConnected
    case notLoggedIn
    case lineupBlocked(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "Enter your MFL username and password."
        case .loginFailed(let m): return m
        case .http(let code, let body): return "MFL error \(code): \(body.prefix(200))"
        case .rateLimited: return "MFL rate limited (429). Wait a moment and try again."
        case .decode(let m): return "Could not parse MFL data: \(m)"
        case .notConnected: return "Connect an MFL league first."
        case .notLoggedIn: return "MFL session expired. Reconnect under Settings → Connect MFL."
        case .lineupBlocked(let m): return m
        case .invalidResponse: return "Unexpected MFL response."
        }
    }
}

/// MyFantasyLeague API client. Registered User-Agent + caching + 429 handling.
actor MFLClient {
    static let shared = MFLClient()

    /// Register this string with MFL's API Client Registration for higher limits.
    static let userAgent = "Sideline/1.0 (com.cpf32.sideline; iOS)"

    private let session: URLSession
    private var cookie: String?
    private let minRequestSpacing: Duration = .milliseconds(1100)
    private var lastRequestAt: ContinuousClock.Instant?

    init(session: URLSession = .shared) {
        self.session = session
        self.cookie = KeychainStore.get(.mflUserCookie)
    }

    func setCookie(_ value: String?) {
        cookie = value
        KeychainStore.set(value, for: .mflUserCookie)
    }

    func currentCookie() -> String? { cookie }

    func login(username: String, password: String, season: Int = Calendar.current.mflSeason) async throws {
        let url = URL(string: "https://api.myfantasyleague.com/\(season)/login")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "USERNAME=\(username.urlEncoded)",
            "PASSWORD=\(password.urlEncoded)",
            "XML=1"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await perform(request, useCache: false, cacheTTL: 0)
        guard let http = response as? HTTPURLResponse else { throw MFLError.invalidResponse }

        if let cookieValue = Self.extractCookie(from: http, data: data, loginURL: url) {
            setCookie(cookieValue)
            KeychainStore.set(username, for: .mflUsername)
            return
        }

        let text = String(data: data, encoding: .utf8) ?? ""
        if text.lowercased().contains("error") {
            throw MFLError.loginFailed(text.strippingTags.prefix(180).description)
        }
        throw MFLError.loginFailed("Login succeeded but no session cookie was returned. Check username/password on myfantasyleague.com.")
    }

    /// Pulls MFL_USER_ID from Set-Cookie, response XML, or the shared cookie jar.
    private static func extractCookie(from http: HTTPURLResponse, data: Data, loginURL: URL) -> String? {
        if let header = http.value(forHTTPHeaderField: "Set-Cookie") {
            for part in header.components(separatedBy: ",") {
                let piece = part.trimmingCharacters(in: .whitespaces)
                if piece.lowercased().hasPrefix("mfl_user_id=") {
                    let value = piece.split(separator: ";", maxSplits: 1).first
                        .map { String($0.dropFirst("MFL_USER_ID=".count)) }
                    if let value, !value.isEmpty { return value }
                }
            }
            // Single cookie form: MFL_USER_ID=...; path=/
            if let match = header.split(separator: ";").first,
               match.lowercased().contains("mfl_user_id") {
                let value = match.split(separator: "=").dropFirst().joined(separator: "=")
                if !value.isEmpty { return String(value) }
            }
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        if let fromXML = text.mflCookieValue { return fromXML }
        if let cookies = HTTPCookieStorage.shared.cookies(for: loginURL) {
            for cookie in cookies where cookie.name.uppercased() == "MFL_USER_ID" {
                return cookie.value
            }
        }
        return nil
    }

    func myLeagues(season: Int = Calendar.current.mflSeason) async throws -> [MFLLeagueSummary] {
        let url = URL(string: "https://api.myfantasyleague.com/\(season)/export?TYPE=myleagues&JSON=1")!
        let data = try await get(url, cacheTTL: 300)
        return try parseMyLeagues(data)
    }

    func exportJSON(
        host: String,
        season: Int,
        type: String,
        leagueId: String,
        extra: [String: String] = [:],
        cacheTTL: TimeInterval = 120
    ) async throws -> Data {
        var comps = URLComponents(string: "https://\(host)/\(season)/export")!
        var items = [
            URLQueryItem(name: "TYPE", value: type),
            URLQueryItem(name: "L", value: leagueId),
            URLQueryItem(name: "JSON", value: "1")
        ]
        for (k, v) in extra { items.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = items
        guard let url = comps.url else { throw MFLError.invalidResponse }
        return try await get(url, cacheTTL: cacheTTL)
    }

    func submitLineup(
        host: String,
        season: Int,
        leagueId: String,
        franchiseId: String,
        week: Int,
        starterIds: [String],
        comments: String? = nil
    ) async throws -> String {
        guard !starterIds.isEmpty else {
            throw MFLError.decode("empty starters")
        }
        guard cookie != nil else {
            throw MFLError.notLoggedIn
        }

        // Owners set their own lineup without FRANCHISE_ID.
        // FRANCHISE_ID is only for commissioners impersonating a franchise — passing it as a
        // normal owner often makes MFL reject the write silently or with a permission error.
        let primary = try await postLineupImport(
            host: host,
            season: season,
            leagueId: leagueId,
            week: week,
            starterIds: starterIds,
            comments: comments,
            franchiseId: nil
        )
        if !Self.importFailed(primary) {
            return primary.isEmpty ? "OK" : primary
        }

        // Commissioner / multi-franchise fallback.
        let withFranchise = try await postLineupImport(
            host: host,
            season: season,
            leagueId: leagueId,
            week: week,
            starterIds: starterIds,
            comments: comments,
            franchiseId: franchiseId
        )
        if Self.importFailed(withFranchise) {
            let cleaned = withFranchise.strippingTags
            throw MFLError.http(200, cleaned.isEmpty ? withFranchise : cleaned)
        }
        return withFranchise.isEmpty ? "OK" : withFranchise
    }

    private func postLineupImport(
        host: String,
        season: Int,
        leagueId: String,
        week: Int,
        starterIds: [String],
        comments: String?,
        franchiseId: String?
    ) async throws -> String {
        // MFL import accepts GET or POST; query-string GET is the documented test-form path.
        var comps = URLComponents(string: "https://\(host)/\(season)/import")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "TYPE", value: "lineup"),
            URLQueryItem(name: "L", value: leagueId),
            URLQueryItem(name: "W", value: String(week)),
            URLQueryItem(name: "STARTERS", value: starterIds.joined(separator: ","))
        ]
        if let franchiseId, !franchiseId.isEmpty {
            items.append(URLQueryItem(name: "FRANCHISE_ID", value: franchiseId))
        }
        if let comments, !comments.isEmpty {
            items.append(URLQueryItem(name: "COMMENTS", value: comments))
        }
        comps.queryItems = items
        guard let url = comps.url else { throw MFLError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        ensureCookieLoaded()
        if let cookie {
            request.setValue("MFL_USER_ID=\(cookie)", forHTTPHeaderField: "Cookie")
        }
        let (data, _) = try await perform(request, useCache: false, cacheTTL: 0)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func importFailed(_ body: String) -> Bool {
        let lower = body.lowercased()
        if lower.contains("<error") { return true }
        if lower.contains("\"error\"") { return true }
        if lower.contains("not logged") { return true }
        if lower.contains("must be logged") { return true }
        if lower.contains("permission") && lower.contains("denied") { return true }
        if lower.contains("not authorized") { return true }
        if lower.contains("invalid franchise") { return true }
        return false
    }

    // MARK: - Internals

    private func get(_ url: URL, cacheTTL: TimeInterval) async throws -> Data {
        ensureCookieLoaded()
        let key = "mfl:\(url.absoluteString)"
        if let policy = Self.cachePolicy(for: cacheTTL),
           let hit = await DataCache.shared.get(key, policy: policy) {
            return hit
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let cookie {
            request.setValue("MFL_USER_ID=\(cookie)", forHTTPHeaderField: "Cookie")
        }
        let (data, _) = try await perform(request, useCache: cacheTTL > 0, cacheTTL: cacheTTL, cacheKey: key)
        return data
    }

    private static func cachePolicy(for ttl: TimeInterval) -> DataCache.Policy? {
        if ttl <= 0 { return nil }
        if ttl <= 90 { return .live }
        if ttl <= 7_200 { return .standard }
        if ttl <= 200_000 { return .day }
        return .week
    }

    /// Global (non-league) exports — e.g. `playerProfile`, which only needs `P=` and no `L`.
    func exportGlobalJSON(
        season: Int,
        type: String,
        extra: [String: String] = [:],
        cacheTTL: TimeInterval = 300
    ) async throws -> Data {
        var comps = URLComponents(string: "https://api.myfantasyleague.com/\(season)/export")!
        var items = [
            URLQueryItem(name: "TYPE", value: type),
            URLQueryItem(name: "JSON", value: "1")
        ]
        for (k, v) in extra { items.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = items
        guard let url = comps.url else { throw MFLError.invalidResponse }
        return try await get(url, cacheTTL: cacheTTL)
    }

    private func ensureCookieLoaded() {
        if cookie == nil {
            cookie = KeychainStore.get(.mflUserCookie)
        }
    }

    private func perform(
        _ request: URLRequest,
        useCache: Bool,
        cacheTTL: TimeInterval,
        cacheKey: String? = nil
    ) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0..<3 {
            if let last = lastRequestAt {
                let elapsed = ContinuousClock.now - last
                if elapsed < minRequestSpacing {
                    try await Task.sleep(for: minRequestSpacing - elapsed)
                }
            }
            lastRequestAt = .now

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw MFLError.invalidResponse }
                if http.statusCode == 429 {
                    // Brief backoff — cold-open bursts often trip MFL's limiter.
                    let delay: Duration = attempt == 0 ? .seconds(2) : .seconds(4)
                    try await Task.sleep(for: delay)
                    lastError = MFLError.rateLimited
                    continue
                }
                if !(200...299).contains(http.statusCode) {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    throw MFLError.http(http.statusCode, body)
                }
                if useCache, cacheTTL > 0, let cacheKey {
                    await DataCache.shared.set(data, for: cacheKey)
                }
                return (data, response)
            } catch let error as MFLError {
                throw error
            } catch {
                // Transient transport failures (flaky Wi‑Fi on launch).
                lastError = error
                if attempt < 2 {
                    try await Task.sleep(for: .milliseconds(800 * (attempt + 1)))
                    continue
                }
                throw error
            }
        }
        throw lastError ?? MFLError.rateLimited
    }

    private func parseMyLeagues(_ data: Data) throws -> [MFLLeagueSummary] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MFLError.decode("root")
        }
        // MFL JSON shapes vary: leagues / myLeagues / league
        let leaguesAny: Any? =
            (root["leagues"] as? [String: Any])?["league"]
            ?? (root["myLeagues"] as? [String: Any])?["league"]
            ?? root["league"]

        let list: [[String: Any]]
        if let arr = leaguesAny as? [[String: Any]] {
            list = arr
        } else if let one = leaguesAny as? [String: Any] {
            list = [one]
        } else {
            return []
        }

        return list.compactMap { dict in
            let leagueId = (dict["league_id"] as? String)
                ?? (dict["id"] as? String)
                ?? (dict["leagueId"] as? String)
            guard let leagueId else { return nil }
            let name = (dict["name"] as? String) ?? (dict["league_name"] as? String) ?? "League \(leagueId)"
            let franchiseId = (dict["franchise_id"] as? String)
                ?? (dict["franchiseId"] as? String)
                ?? "0001"
            let franchiseName = (dict["franchise_name"] as? String)
                ?? (dict["franchiseName"] as? String)
                ?? (dict["fname"] as? String)
                ?? (dict["team"] as? String)
            let resolvedFranchiseName: String = {
                if let franchiseName {
                    let trimmed = franchiseName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
                return "Franchise"
            }()
            let host = (dict["url"] as? String).flatMap { URL(string: $0)?.host }
                ?? (dict["host"] as? String)
                ?? "api.myfantasyleague.com"
            return MFLLeagueSummary(
                leagueId: leagueId,
                name: name,
                franchiseId: franchiseId,
                franchiseName: resolvedFranchiseName,
                host: host,
                url: dict["url"] as? String
            )
        }
    }
}

extension Calendar {
    var mflSeason: Int {
        let year = component(.year, from: Date())
        let month = component(.month, from: Date())
        // Jan still belongs to prior NFL season year in MFL
        return month == 1 ? year - 1 : year
    }
}

extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }

    var strippingTags: String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var mflCookieValue: String? {
        // <cookie name="MFL_USER_ID" value="...">
        guard let range = range(of: #"value="([^"]+)""#, options: .regularExpression) else { return nil }
        let match = self[range]
        guard let open = match.range(of: "value=\"") else { return nil }
        let start = open.upperBound
        guard let close = match[start...].firstIndex(of: "\"") else { return nil }
        return String(match[start..<close])
    }
}
