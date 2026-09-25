import Foundation

/// Fetches shared public blobs from the Sideline Cloudflare Worker cache.
/// Falls back to upstream vendor URLs when the Worker is unreachable.
enum SidelinePublicClient {
    static var backendBaseURL: String {
        LiveActivityPushClient.backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let userAgent = "Sideline/1.0 (com.cpf32.sideline; iOS)"

    /// Prefer Worker public cache; on failure call `upstream`.
    static func data(
        path: String,
        query: [String: String] = [:],
        revalidate: Bool = false,
        timeout: TimeInterval = 30,
        upstream: @Sendable () async throws -> Data
    ) async throws -> Data {
        if let cached = try? await fetchFromWorker(
            path: path,
            query: query,
            revalidate: revalidate,
            timeout: timeout,
            headers: [:]
        ) {
            return cached
        }
        return try await upstream()
    }

    /// Per-user BYOK proxy+cache on the Worker (FantasyPros / Odds).
    /// Requires backend URL + register secret. Falls back to `upstream` when Worker is down.
    static func byokData(
        path: String,
        query: [String: String] = [:],
        vendorAPIKey: String,
        live: Bool = false,
        revalidate: Bool = false,
        timeout: TimeInterval = 45,
        upstream: @Sendable () async throws -> Data
    ) async throws -> Data {
        let secret = LiveActivityPushClient.registerSecret
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let userId = KeychainStore.get(.appleUserID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !secret.isEmpty, !userId.isEmpty, vendorAPIKey.count >= 8 else {
            return try await upstream()
        }

        var headers: [String: String] = [
            "X-Sideline-Key": secret,
            "X-Sideline-User-Id": userId,
            "X-Vendor-API-Key": vendorAPIKey,
        ]
        if live {
            headers["X-Sideline-Live"] = "1"
        }

        if let cached = try? await fetchFromWorker(
            path: path,
            query: query,
            revalidate: revalidate,
            timeout: timeout,
            headers: headers
        ) {
            return cached
        }
        return try await upstream()
    }

    private static func fetchFromWorker(
        path: String,
        query: [String: String],
        revalidate: Bool,
        timeout: TimeInterval,
        headers: [String: String]
    ) async throws -> Data {
        let base = backendBaseURL
        guard base.hasPrefix("http"),
              var components = URLComponents(string: base)
        else {
            throw URLError(.badURL)
        }

        let trimmedPath = path.hasPrefix("/") ? path : "/" + path
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath.isEmpty {
            components.path = trimmedPath
        } else {
            components.path = "/" + basePath + trimmedPath
        }

        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        if revalidate {
            items.append(URLQueryItem(name: "revalidate", value: "1"))
        }
        components.queryItems = items.isEmpty ? nil : items

        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if revalidate {
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        guard !data.isEmpty else { throw URLError(.zeroByteResource) }
        return data
    }
}
