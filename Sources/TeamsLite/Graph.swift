import Foundation

enum GraphError: LocalizedError {
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let message): return message.isEmpty ? "Microsoft Graph returned HTTP \(code)." : message
        }
    }

    var status: Int {
        switch self { case .http(let code, _): return code }
    }
}

/// Minimal Microsoft Graph REST client: bearer auth, one retry after 401, Retry-After on throttling.
@MainActor
final class Graph {
    let auth: Auth
    private let http: URLSession

    init(auth: Auth, http: URLSession) {
        self.auth = auth
        self.http = http
    }

    func url(_ path: String, _ query: [(String, String)] = [], beta: Bool = false) -> URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = "graph.microsoft.com"
        c.path = (beta ? "/beta" : "/v1.0") + path
        if !query.isEmpty {
            c.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
            // URLComponents leaves "+" alone, which servers read as a space.
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return c.url!
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String, _ query: [(String, String)] = []) async throws -> T {
        try await get(type, url: url(path, query))
    }

    func get<T: Decodable>(_ type: T.Type, url: URL) async throws -> T {
        let data = try await send("GET", url)
        return try await Self.decode(type, data)
    }

    /// `presence: true` authorizes with the separate Presence.ReadWrite token.
    @discardableResult
    func send(_ method: String, _ url: URL, json: Any? = nil, accept: String = "application/json",
              presence: Bool = false) async throws -> Data {
        var attempt = 0
        var forceRefresh = false
        while true {
            attempt += 1
            var req = URLRequest(url: url)
            req.httpMethod = method
            let token = presence ? try await auth.presenceAccessToken() : try await auth.token(forceRefresh: forceRefresh)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(accept, forHTTPHeaderField: "Accept")
            if let json {
                req.httpBody = try JSONSerialization.data(withJSONObject: json)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, resp) = try await http.data(for: req)
            let response = resp as? HTTPURLResponse
            let status = response?.statusCode ?? 0
            if (200..<300).contains(status) { return data }
            log.info("Graph \(method, privacy: .public) \(url.path, privacy: .public) -> \(status)")
            if status == 401, !forceRefresh, !presence {
                forceRefresh = true
                continue
            }
            if [429, 503, 504].contains(status), attempt < 3 {
                let wait = Double(response?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(2 * attempt)
                try await Task.sleep(nanoseconds: UInt64(min(max(wait, 1), 30) * 1_000_000_000))
                continue
            }
            throw GraphError.http(status, Self.errorMessage(data))
        }
    }

    /// Decoding runs off the main actor.
    nonisolated static func decode<T: Decodable>(_ type: T.Type, _ data: Data) async throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    private static func errorMessage(_ data: Data) -> String {
        struct Body: Decodable {
            struct Inner: Decodable { let code: String?; let message: String? }
            let error: Inner?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return "" }
        return body.error?.message ?? body.error?.code ?? ""
    }
}
