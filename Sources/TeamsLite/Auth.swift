import AppKit
import CryptoKit
import Network

/// Persisted sign-in state (stored as one keychain item).
struct Session: Codable {
    var refreshToken: String
    var userId: String
    var tenantId: String
    var displayName: String
    var username: String
    /// Relay room id (secret path segment) and Graph subscription clientState.
    var roomId: String
    var clientState: String
}

enum AuthError: LocalizedError {
    case notSignedIn
    case cancelled
    case timedOut
    case stateMismatch
    case oauth(code: String, message: String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in."
        case .cancelled: return "Sign-in was cancelled."
        case .timedOut: return "Sign-in timed out. Please try again."
        case .stateMismatch: return "Sign-in response did not match the request. Please try again."
        case .oauth(_, let message): return message.components(separatedBy: "\r\n").first ?? message
        case .server(let message): return message
        }
    }

    /// The refresh token is no longer usable; the user has to sign in again.
    var needsSignIn: Bool {
        if case .oauth(let code, _) = self { return code == "invalid_grant" || code == "interaction_required" }
        if case .notSignedIn = self { return true }
        return false
    }
}

/// OAuth 2.0 against Microsoft Entra ID: authorization code + PKCE with a loopback
/// redirect (system browser), device code as a fallback, refresh tokens in the keychain.
@MainActor
final class Auth {
    struct DeviceCode: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let expires_in: Int
        let interval: Int?
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
        let id_token: String?
    }

    private struct OAuthErrorBody: Decodable {
        let error: String
        let error_description: String?
    }

    private(set) var session: Session?
    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private var refreshing: Task<String, Error>?
    private let http: URLSession

    init(http: URLSession) {
        self.http = http
    }

    private var endpoint: String { "https://login.microsoftonline.com/\(Config.tenant)/oauth2/v2.0" }

    // MARK: Session storage

    func loadSession() -> Bool {
        guard let data = Keychain.read("session"),
              let s = try? JSONDecoder().decode(Session.self, from: data) else { return false }
        session = s
        return true
    }

    func clear() {
        session = nil
        accessToken = nil
        presenceToken = nil
        expiresAt = .distantPast
        refreshing?.cancel()
        refreshing = nil
        Keychain.delete("session")
    }

    private func persist() {
        guard let session, let data = try? JSONEncoder().encode(session) else { return }
        Keychain.write(data, account: "session")
    }

    // MARK: Access tokens

    func token(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let accessToken, expiresAt > Date().addingTimeInterval(120) { return accessToken }
        if let refreshing { return try await refreshing.value }
        guard let refreshToken = session?.refreshToken else { throw AuthError.notSignedIn }
        let task = Task { () throws -> String in
            let r = try await self.requestToken(["grant_type": "refresh_token",
                                                  "refresh_token": refreshToken,
                                                  "scope": Config.scopes])
            self.apply(r)
            return r.access_token
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private var presenceToken: String?
    private var presenceExpiresAt = Date.distantPast

    /// Separate token for Presence.ReadWrite. Failing here (e.g. permission not granted yet)
    /// must never end the main session, so it has its own cache and error path.
    func presenceAccessToken() async throws -> String {
        if let presenceToken, presenceExpiresAt > Date().addingTimeInterval(120) { return presenceToken }
        guard let refreshToken = session?.refreshToken else { throw AuthError.notSignedIn }
        let r = try await requestToken(["grant_type": "refresh_token",
                                        "refresh_token": refreshToken,
                                        "scope": Config.presenceScope])
        presenceToken = r.access_token
        presenceExpiresAt = Date().addingTimeInterval(TimeInterval(r.expires_in ?? 3600))
        if let rt = r.refresh_token, rt != session?.refreshToken {
            session?.refreshToken = rt
            persist()
        }
        return r.access_token
    }

    private func apply(_ r: TokenResponse) {
        accessToken = r.access_token
        expiresAt = Date().addingTimeInterval(TimeInterval(r.expires_in ?? 3600))
        if let rt = r.refresh_token, session != nil, rt != session?.refreshToken {
            session?.refreshToken = rt
            persist()
        }
    }

    // MARK: Interactive sign-in

    /// `extraScopes` asks for additional consent (e.g. presence) in the same browser round trip.
    func signInWithBrowser(loginHint: String?, extraScopes: String = "") async throws {
        let scopes = extraScopes.isEmpty ? Config.scopes : Config.scopes + " " + extraScopes
        let verifier = Self.randomURLSafe(32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(16)

        let server = try LoopbackServer()
        let port = try await server.start()
        defer { server.stop() }
        let redirect = "http://localhost:\(port)"

        var c = URLComponents(string: endpoint + "/authorize")!
        var items = [URLQueryItem(name: "client_id", value: Config.clientID),
                     URLQueryItem(name: "response_type", value: "code"),
                     URLQueryItem(name: "redirect_uri", value: redirect),
                     URLQueryItem(name: "response_mode", value: "query"),
                     URLQueryItem(name: "scope", value: scopes),
                     URLQueryItem(name: "state", value: state),
                     URLQueryItem(name: "code_challenge", value: challenge),
                     URLQueryItem(name: "code_challenge_method", value: "S256")]
        if let loginHint, !loginHint.isEmpty { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        c.queryItems = items
        NSWorkspace.shared.open(c.url!)

        let params = try await server.waitForRedirect(timeout: 300)
        if let error = params["error"] {
            throw AuthError.oauth(code: error, message: params["error_description"] ?? error)
        }
        guard params["state"] == state else { throw AuthError.stateMismatch }
        guard let code = params["code"] else { throw AuthError.server("No authorization code was returned.") }

        let r = try await requestToken(["grant_type": "authorization_code",
                                        "code": code,
                                        "redirect_uri": redirect,
                                        "code_verifier": verifier,
                                        "scope": scopes])
        try establish(r)
    }

    func startDeviceCode() async throws -> DeviceCode {
        let (data, status) = try await postForm(endpoint + "/devicecode",
                                                ["client_id": Config.clientID, "scope": Config.scopes])
        guard status == 200 else { throw Self.oauthError(data, status: status) }
        return try JSONDecoder().decode(DeviceCode.self, from: data)
    }

    func completeDeviceCode(_ dc: DeviceCode) async throws {
        var interval = UInt64(max(dc.interval ?? 5, 1))
        let deadline = Date().addingTimeInterval(TimeInterval(dc.expires_in))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: interval * 1_000_000_000)
            do {
                let r = try await requestToken(["grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                                                "device_code": dc.device_code])
                try establish(r)
                return
            } catch AuthError.oauth(let code, _) where code == "authorization_pending" {
                continue
            } catch AuthError.oauth(let code, _) where code == "slow_down" {
                interval += 5
            }
        }
        throw AuthError.timedOut
    }

    private func establish(_ r: TokenResponse) throws {
        guard let refreshToken = r.refresh_token else {
            throw AuthError.server("Microsoft did not return a refresh token (offline_access).")
        }
        let claims = Self.jwtClaims(r.id_token ?? r.access_token)
        let userId = claims["oid"] as? String ?? ""
        guard !userId.isEmpty else { throw AuthError.server("Could not read the signed-in user.") }
        var s = Session(refreshToken: refreshToken,
                        userId: userId,
                        tenantId: claims["tid"] as? String ?? "",
                        displayName: claims["name"] as? String ?? "",
                        username: claims["preferred_username"] as? String ?? "",
                        roomId: Self.randomHex(32),
                        clientState: Self.randomHex(16))
        if let old = session, old.userId == userId {
            s.roomId = old.roomId
            s.clientState = old.clientState
        }
        session = s
        accessToken = r.access_token
        expiresAt = Date().addingTimeInterval(TimeInterval(r.expires_in ?? 3600))
        persist()
        UserDefaults.standard.set(s.username, forKey: "lastUsername")
    }

    // MARK: HTTP

    private func requestToken(_ params: [String: String]) async throws -> TokenResponse {
        var p = params
        p["client_id"] = Config.clientID
        let (data, status) = try await postForm(endpoint + "/token", p)
        guard status == 200 else { throw Self.oauthError(data, status: status) }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func postForm(_ url: String, _ params: [String: String]) async throws -> (Data, Int) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(params.map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&").utf8)
        let (data, resp) = try await http.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func oauthError(_ data: Data, status: Int) -> AuthError {
        if let e = try? JSONDecoder().decode(OAuthErrorBody.self, from: data) {
            return .oauth(code: e.error, message: e.error_description ?? e.error)
        }
        return .server("Sign-in service returned HTTP \(status).")
    }

    // MARK: Helpers

    private static let formAllowed: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-._~")
        return s
    }()

    private static func formEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? s
    }

    private static func randomBytes(_ n: Int) -> Data {
        var d = Data(count: n)
        _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        return d
    }

    static func randomHex(_ bytes: Int) -> String {
        randomBytes(bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomURLSafe(_ bytes: Int) -> String { base64URL(randomBytes(bytes)) }

    private static func base64URL(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func jwtClaims(_ jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }
}

/// One-shot HTTP listener on localhost that captures the OAuth redirect.
final class LoopbackServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "TeamsLite.loopback")
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    init() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            final class Flag { var done = false }
            let resumed = Flag()  // only touched on `queue`
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed.done else { return }
                switch state {
                case .ready:
                    resumed.done = true
                    cont.resume(returning: self?.listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed.done = true
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: String], Error>) in
                queue.async {
                    if let result = self.result {
                        cont.resume(with: result)
                        return
                    }
                    self.continuation = cont
                    self.queue.asyncAfter(deadline: .now() + timeout) { self.finish(.failure(AuthError.timedOut)) }
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(AuthError.cancelled)) }
        }
    }

    private func finish(_ r: Result<[String: String], Error>) {
        guard result == nil else { return }
        result = r
        continuation?.resume(with: r)
        continuation = nil
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(conn, head: String(decoding: buf[..<end.lowerBound], as: UTF8.self))
            } else if complete || error != nil || buf.count > 65536 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func handle(_ conn: NWConnection, head: String) {
        let requestLine = head.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, let comps = URLComponents(string: "http://localhost" + parts[1]) else {
            respond(conn, status: "400 Bad Request", body: "Bad request")
            return
        }
        var params: [String: String] = [:]
        for item in comps.queryItems ?? [] { params[item.name] = item.value ?? "" }
        guard params["code"] != nil || params["error"] != nil else {
            respond(conn, status: "404 Not Found", body: "Not found")
            return
        }
        let ok = params["error"] == nil
        let message = ok ? "You are signed in to TeamsLite. You can close this tab."
                         : "Sign-in failed. Return to TeamsLite for details."
        respond(conn, status: "200 OK", body: """
            <!doctype html><html><head><meta charset="utf-8"><title>TeamsLite</title></head>
            <body style="font:16px -apple-system,sans-serif;text-align:center;padding-top:80px">\(message)</body></html>
            """)
        finish(.success(params))
    }

    private func respond(_ conn: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in conn.cancel() })
    }
}
