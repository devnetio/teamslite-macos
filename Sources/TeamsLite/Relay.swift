import Foundation

/// WebSocket to the relay Worker. Graph change notifications arrive here, so the
/// app never polls. A 30 s heartbeat ("ping" -> "pong", answered by the Durable
/// Object runtime without waking it) keeps idle connections open.
@MainActor
final class Relay: NSObject, URLSessionWebSocketDelegate {
    enum State: Equatable {
        case off, connecting, live
        case offline(String)
    }

    private(set) var state: State = .off {
        didSet { if state != oldValue { onState?(state) } }
    }
    var onState: ((State) -> Void)?
    var onMessage: ((Data) -> Void)?
    /// Called after every successful (re)connect with the length of the outage, if any.
    var onConnected: ((TimeInterval?) -> Void)?

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
    }()
    private var task: URLSessionWebSocketTask?
    private var endpoint: URL?
    private var pingTimer: Timer?
    private var retryTimer: Timer?
    private var retryDelay: TimeInterval = 2
    private var lastSeen = Date()
    private var droppedAt: Date?

    func connect(_ url: URL) {
        endpoint = url
        retryDelay = 2
        open()
    }

    func disconnect() {
        endpoint = nil
        teardown()
        state = .off
    }

    /// After network changes: skip the backoff wait.
    func reconnectIfNeeded() {
        guard endpoint != nil, state != .live, state != .connecting else { return }
        open()
    }

    /// After sleep the socket is dead even if it doesn't know yet; reconnect and resync.
    func restart() {
        guard endpoint != nil else { return }
        droppedAt = .distantPast
        open()
    }

    private func open() {
        guard let endpoint, var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return }
        teardown()
        comps.scheme = comps.scheme == "http" ? "ws" : "wss"
        guard let url = comps.url else { return }
        state = .connecting
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receive(t)
    }

    private func teardown() {
        pingTimer?.invalidate()
        pingTimer = nil
        retryTimer?.invalidate()
        retryTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                switch result {
                case .success(let message):
                    self.lastSeen = Date()
                    switch message {
                    case .string(let s): if s != "pong" { self.onMessage?(Data(s.utf8)) }
                    case .data(let d): self.onMessage?(d)
                    @unknown default: break
                    }
                    self.receive(t)
                case .failure(let error):
                    self.dropped(error.localizedDescription)
                }
            }
        }
    }

    private func dropped(_ reason: String) {
        teardown()
        guard endpoint != nil else { return }
        log.info("Relay disconnected: \(reason, privacy: .public)")
        if droppedAt == nil { droppedAt = Date() }
        state = .offline(reason)
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60)
        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.open() }
        }
    }

    private func startHeartbeat() {
        pingTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.heartbeat() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func heartbeat() {
        guard let task else { return }
        if Date().timeIntervalSince(lastSeen) > 80 {
            dropped("heartbeat timeout")
            return
        }
        task.send(.string("ping")) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                if self?.task === task { self?.dropped(error.localizedDescription) }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            guard webSocketTask === self.task else { return }
            self.state = .live
            self.retryDelay = 2
            self.lastSeen = Date()
            let outage = self.droppedAt.map { Date().timeIntervalSince($0) }
            self.droppedAt = nil
            self.startHeartbeat()
            self.onConnected?(outage)
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in
            if webSocketTask === self.task { self.dropped("closed (\(closeCode.rawValue))") }
        }
    }
}
