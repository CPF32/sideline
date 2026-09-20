import Foundation

enum MFLError: LocalizedError {
    case missingCredentials
    case loginFailed(String)
    case http(Int, String)
    case rateLimited
    case decode(String)
    case notConnected
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "Enter your MFL username and password."
        case .loginFailed(let m): return m
        case .http(let code, let body): return "MFL error \(code): \(body.prefix(200))"
        case .rateLimited: return "MFL rate limited (429). Wait a moment and try again."
        case .decode(let m): return "Could not parse MFL data: \(m)"
        case .notConnected: return "Connect an MFL league first."
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
    private var cache: [String: (date: Date, data: Data)] = [:]
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

        if let header = http.value(forHTTPHeaderField: "Set-Cookie"),
           let match = header.split(separator: ";").first,
           match.lowercased().contains("mfl_user_id") {
            let value = match.split(separator: "=").dropFirst().joined(separator: "=")
            setCookie(String(value))
            KeychainStore.set(username, for: .mflUsername)
            return
        }

        // Fallback: parse XML for cookie attribute
        let text = String(data: data, encoding: .utf8) ?? ""
        if text.lowercased().contains("error") {
            throw MFLError.loginFailed(text.strippingTags.prefix(180).description)
        }
        if let cookieValue = text.mflCookieValue {
            setCookie(cookieValue)
            KeychainStore.set(username, for: .mflUsername)
            return
        }
        throw MFLError.loginFailed("Login succeeded but no session cookie was returned.")
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
        week: Int,
        starterIds: [String],
        comments: String? = nil
    ) async throws -> String {
        var comps = URLComponents(string: "https://\(host)/\(season)/import")!
        comps.queryItems = [
            URLQueryItem(name: "TYPE", value: "lineup"),
            URLQueryItem(name: "L", value: leagueId),
            URLQueryItem(name: "W", value: String(week)),
            URLQueryItem(name: "STARTERS", value: starterIds.joined(separator: ",")),
            URLQueryItem(name: "JSON", value: "1")
        ]
        if let comments, !comments.isEmpty {
            comps.queryItems?.append(URLQueryItem(name: "COMMENTS", value: comments))
        }
        guard let url = comps.url else { throw MFLError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let cookie {
            request.setValue("MFL_USER_ID=\(cookie)", forHTTPHeaderField: "Cookie")
        }
        let (data, _) = try await perform(request, useCache: false, cacheTTL: 0)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Internals

    private func get(_ url: URL, cacheTTL: TimeInterval) async throws -> Data {
        let key = url.absoluteString
        if cacheTTL > 0, let hit = cache[key], Date().timeIntervalSince(hit.date) < cacheTTL {
            return hit.data
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

    private func perform(
        _ request: URLRequest,
        useCache: Bool,
        cacheTTL: TimeInterval,
        cacheKey: String? = nil
    ) async throws -> (Data, URLResponse) {
        if let last = lastRequestAt {
            let elapsed = ContinuousClock.now - last
            if elapsed < minRequestSpacing {
                try await Task.sleep(for: minRequestSpacing - elapsed)
            }
        }
        lastRequestAt = .now

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MFLError.invalidResponse }
        if http.statusCode == 429 { throw MFLError.rateLimited }
        if !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MFLError.http(http.statusCode, body)
        }
        if useCache, cacheTTL > 0, let cacheKey {
            cache[cacheKey] = (Date(), data)
        }
        return (data, response)
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
