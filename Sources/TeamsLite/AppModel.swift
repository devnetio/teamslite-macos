import AppKit

/// App state and all Teams logic. Data flow: one GET of the chat list at start-up
/// (and after outages), message GETs only when a chat is opened or a change
/// notification arrives through the relay. Nothing is polled on a timer.
@MainActor
final class AppModel {
    let auth: Auth
    let graph: Graph
    let relay = Relay()
    let notifier = Notifier()
    let images: ImageStore

    private(set) var chats: [Chat] = []
    private var chatsById: [String: Chat] = [:]
    private var conversations: [String: Conversation] = [:]
    private var recent: [String] = []
    private(set) var currentChatId: String?
    private(set) var signedIn = false
    private(set) var demo = false
    private(set) var errorText: String?
    private(set) var subscriptionError: String?
    var signInNotice: String?
    var drafts: [String: String] = [:]

    private var lastRefresh = Date.distantPast
    private var refreshing = false
    private var bulkMembersLoaded = false
    private var fetching: Set<String> = []
    private var refetch: Set<String> = []
    private var renewTimer: Timer?
    private var renewRetry: TimeInterval = 60
    private var activity: NSObjectProtocol?
    private var demoUser = ("", "")
    private var presenceTimer: Timer?
    private(set) var presence: PresenceState = .off
    var draftImages: [String: [OutgoingImage]] = [:]

    enum PresenceState: Equatable {
        case off, available, needsConsent
        case failed(String)
    }

    // UI hooks (set by the window controllers).
    var onSessionChange: (() -> Void)?
    var onChatsChange: (() -> Void)?
    var onConversationChange: ((_ chatId: String, _ prependedOlder: Bool) -> Void)?
    var onStatusChange: (() -> Void)?
    var onSendFailed: ((_ chatId: String, _ text: String, _ images: [OutgoingImage]) -> Void)?
    /// Presence.ReadWrite hasn't been granted yet; the UI offers the one-time consent.
    var onPresenceNeedsConsent: (() -> Void)?
    var onOpenChatRequest: ((String) -> Void)?
    var isWindowVisible: () -> Bool = { false }

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 30
        let http = URLSession(configuration: cfg)
        auth = Auth(http: http)
        graph = Graph(auth: auth, http: http)
        images = ImageStore(graph: graph, http: http)
        relay.onMessage = { [weak self] data in self?.handleRelay(data) }
        relay.onConnected = { [weak self] outage in self?.relayConnected(outage: outage) }
        relay.onState = { [weak self] _ in self?.onStatusChange?() }
        notifier.onOpenChat = { [weak self] id in self?.onOpenChatRequest?(id) }
        images.onLoaded = { [weak self] _ in
            guard let self, let id = self.currentChatId else { return }
            self.onConversationChange?(id, false)
        }
    }

    var me: String { demo ? demoUser.0 : auth.session?.userId ?? "" }
    var myName: String { demo ? demoUser.1 : auth.session?.displayName ?? "" }
    var username: String { auth.session?.username ?? "" }

    func chat(_ id: String) -> Chat? { chatsById[id] }
    func title(of chat: Chat) -> String { chat.title(me: me, myName: myName) }

    /// One-line connection summary for the sidebar, plus details for its tooltip.
    var liveStatus: (text: String, color: NSColor, detail: String) {
        if demo { return ("Demo data", .systemOrange, "Started with --demo; nothing is sent to Microsoft.") }
        if let errorText { return (errorText, .systemOrange, errorText) }
        if Config.relayURL == nil { return ("Live updates off", .tertiaryLabelColor, "Set a relay URL in Settings to receive messages instantly.") }
        switch relay.state {
        case .off, .connecting: return ("Connecting…", .systemYellow, "Connecting to the relay.")
        case .offline(let reason): return ("Reconnecting…", .systemOrange, "Relay unreachable: \(reason)")
        case .live:
            if let subscriptionError { return ("No live updates", .systemOrange, subscriptionError) }
            switch presence {
            case .available: return ("Live · Available", .systemGreen, "Receiving change notifications. Your Teams status is kept at Available.")
            case .needsConsent: return ("Live · status needs permission", .systemGreen, "Grant the presence permission from the TeamsLite menu to stay Available.")
            case .failed(let why): return ("Live · status update failed", .systemGreen, why)
            case .off: return ("Live", .systemGreen, "Receiving Microsoft Graph change notifications.")
            }
        }
    }

    // MARK: - Lifecycle

    func start(demo: Bool) {
        if demo {
            self.demo = true
            signedIn = true
            onSessionChange?()
            DemoData.load(into: self)
            return
        }
        signedIn = auth.loadSession()
        onSessionChange?()
        if signedIn { Task { await bootstrap() } }
    }

    private func bootstrap() async {
        if activity == nil {
            // Keep App Nap from stretching the relay heartbeat; idle CPU use stays at zero.
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                             reason: "Receiving Teams messages")
        }
        notifier.setup()
        await refreshChats(initial: true)
        guard signedIn else { return }
        connectRelay()
        await updatePresence()
    }

    func signInWithBrowser() async throws {
        try await auth.signInWithBrowser(loginHint: UserDefaults.standard.string(forKey: "lastUsername"))
        didSignIn()
    }

    func startDeviceCode() async throws -> Auth.DeviceCode {
        try await auth.startDeviceCode()
    }

    func completeDeviceCode(_ code: Auth.DeviceCode) async throws {
        try await auth.completeDeviceCode(code)
        didSignIn()
    }

    private func didSignIn() {
        signInNotice = nil
        signedIn = true
        onSessionChange?()
        Task { await bootstrap() }
    }

    func signOut() async {
        await clearPresence()
        if let id = UserDefaults.standard.string(forKey: "subscriptionId"), auth.session != nil {
            let beta = UserDefaults.standard.bool(forKey: "subscriptionBeta")
            _ = try? await graph.send("DELETE", graph.url("/subscriptions/\(id)", beta: beta))
        }
        reset(notice: nil)
    }

    private func reset(notice: String?) {
        UserDefaults.standard.removeObject(forKey: "subscriptionId")
        relay.disconnect()
        renewTimer?.invalidate()
        renewTimer = nil
        auth.clear()
        chats = []
        chatsById = [:]
        conversations = [:]
        recent = []
        currentChatId = nil
        drafts = [:]
        bulkMembersLoaded = false
        lastRefresh = .distantPast
        errorText = nil
        subscriptionError = nil
        signedIn = false
        signInNotice = notice
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        notifier.clearAll()
        presenceTimer?.invalidate()
        presenceTimer = nil
        presence = .off
        images.clear()
        draftImages = [:]
        updateBadge()
        onSessionChange?()
    }

    func appDidBecomeActive() {
        guard signedIn, !demo else { return }
        if let id = currentChatId { markReadIfVisible(id) }
        relay.reconnectIfNeeded()
        // User-driven resync (read state from other devices); never on a timer.
        if Date().timeIntervalSince(lastRefresh) > 120 {
            Task {
                await refreshChats()
                if let id = currentChatId { await loadLatest(id) }
            }
        }
    }

    func didWake() {
        guard signedIn, !demo else { return }
        relay.restart()
        Task { await updatePresence() }
    }

    func refreshAll() async {
        guard signedIn, !demo else { return }
        await refreshChats()
        if let id = currentChatId { await loadLatest(id) }
        relay.reconnectIfNeeded()
        if relay.state == .live { await ensureSubscription() }
    }

    func relaySettingsChanged() {
        guard signedIn, !demo else { return }
        relay.disconnect()
        subscriptionError = nil
        connectRelay()
        onStatusChange?()
    }

    // MARK: - Chats

    func refreshChats(initial: Bool = false) async {
        guard signedIn, !demo, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let page = try await graph.get(Page<ChatDTO>.self, "/me/chats", [
                ("$expand", "lastMessagePreview"),
                ("$orderby", "lastMessagePreview/createdDateTime desc"),
                ("$top", "50"),
            ])
            let firstLoad = chatsById.isEmpty
            var fresh: [Chat] = []
            for dto in page.value {
                let chat = chatsById[dto.id] ?? Chat(id: dto.id)
                chatsById[dto.id] = chat
                let previous = chat.lastMessageId
                chat.update(from: dto, me: me)
                if !firstLoad, !initial, chat.lastMessageId != previous, chat.isUnread(me: me) { fresh.append(chat) }
            }
            lastRefresh = Date()
            setError(nil)
            rebuildList()
            await loadMemberNames()
            // Messages that arrived while the relay was unreachable.
            for chat in fresh.prefix(3) where !isVisible(chat.id) {
                notify(chat, sender: chat.lastSenderName, text: chat.lastPreview)
            }
        } catch {
            handle(error, context: "Loading chats")
        }
    }

    private func loadMemberNames() async {
        let missing = chats.filter(\.needsMemberNames)
        guard !missing.isEmpty else { return }
        if missing.count > 3, !bulkMembersLoaded {
            bulkMembersLoaded = true
            if let page = try? await graph.get(Page<ChatDTO>.self, "/me/chats", [
                ("$expand", "members"),
                ("$orderby", "lastMessagePreview/createdDateTime desc"),
                ("$top", "50"),
            ]) {
                for dto in page.value {
                    if let members = dto.members { chatsById[dto.id]?.setMembers(members, me: me) }
                }
            }
        }
        for chat in chats where chat.needsMemberNames {
            await loadMembers(chat)
        }
        onChatsChange?()
    }

    private func loadMembers(_ chat: Chat) async {
        if let page = try? await graph.get(Page<MemberDTO>.self, "/chats/\(chat.id)/members") {
            chat.setMembers(page.value, me: me)
        }
    }

    private func rebuildList() {
        chats = chatsById.values
            .filter { !$0.hidden || $0.id == currentChatId }
            .sorted { $0.sortDate > $1.sortDate }
        onChatsChange?()
        updateBadge()
    }

    private func updateBadge() {
        let unread = chats.filter { $0.isUnread(me: me) }.count
        NSApp.dockTile.badgeLabel = unread > 0 ? "\(unread)" : nil
    }

    // MARK: - Conversations

    func conversation(_ id: String) -> Conversation {
        recent.removeAll { $0 == id }
        recent.append(id)
        // Keep only a handful of recently viewed chats in memory.
        while recent.count > 6 {
            let evicted = recent.removeFirst()
            if evicted != currentChatId { conversations[evicted] = nil }
        }
        if let c = conversations[id] { return c }
        let c = Conversation()
        conversations[id] = c
        return c
    }

    func openChat(_ id: String?) {
        currentChatId = id
        guard let id else { return }
        _ = conversation(id)
        onConversationChange?(id, false)
        if !demo { Task { await loadLatest(id) } }
        markReadIfVisible(id)
    }

    func loadLatest(_ id: String) async {
        let conv = conversation(id)
        guard !conv.loading else { return }
        conv.loading = true
        defer { conv.loading = false }
        do {
            let page = try await graph.get(Page<MessageDTO>.self, "/chats/\(id)/messages", [
                ("$top", "50"),
                ("$orderby", "createdDateTime desc"),
            ])
            for dto in page.value {
                if let m = Message(dto) { conv.upsert(m) }
            }
            if !conv.loaded { conv.olderLink = page.nextLink }
            conv.loaded = true
            if let newest = conv.messages.last { chatsById[id]?.applyMessage(newest) }
            setError(nil)
            onConversationChange?(id, false)
        } catch {
            handle(error, context: "Loading messages")
        }
    }

    func loadOlder(_ id: String) {
        guard !demo, let conv = conversations[id], !conv.loading,
              let link = conv.olderLink, let url = URL(string: link) else { return }
        conv.loading = true
        Task {
            defer { conv.loading = false }
            do {
                let page = try await graph.get(Page<MessageDTO>.self, url: url)
                for dto in page.value {
                    if let m = Message(dto) { conv.upsert(m) }
                }
                conv.olderLink = page.nextLink
                onConversationChange?(id, true)
            } catch {
                handle(error, context: "Loading older messages")
            }
        }
    }

    func send(_ text: String, images outgoing: [OutgoingImage] = [], to id: String) {
        let conv = conversation(id)
        let pending = PendingMessage(text: text, imageCount: outgoing.count)
        conv.pending.append(pending)
        onConversationChange?(id, false)
        if demo {
            DemoData.echo(text, chatId: id, into: self)
            conv.pending.removeAll { $0.id == pending.id }
            return
        }
        Task {
            do {
                var html = text.isEmpty ? "" : HTML.fromPlainText(text)
                var hosted: [[String: Any]] = []
                for (i, img) in outgoing.enumerated() {
                    // Shown at most 480 px wide in Teams; the full image is still uploaded.
                    let scale = min(1, 480 / Double(max(img.pixelWidth, 1)))
                    let w = Int(Double(img.pixelWidth) * scale), h = Int(Double(img.pixelHeight) * scale)
                    html += "<div><img src=\"../hostedContents/\(i + 1)/$value\" style=\"vertical-align:bottom; width:\(w)px; height:\(h)px\"></div>"
                    hosted.append(["@microsoft.graph.temporaryId": "\(i + 1)",
                                   "contentBytes": img.data.base64EncodedString(),
                                   "contentType": img.contentType])
                }
                var payload: [String: Any] = ["body": ["contentType": "html", "content": html]]
                if !hosted.isEmpty { payload["hostedContents"] = hosted }
                let data = try await graph.send("POST", graph.url("/chats/\(id)/messages"), json: payload)
                let dto = try await Graph.decode(MessageDTO.self, data)
                conv.pending.removeAll { $0.id == pending.id }
                if let m = Message(dto) {
                    conv.upsert(m)
                    chatsById[id]?.applyMessage(m)
                }
                rebuildList()
                onConversationChange?(id, false)
            } catch {
                conv.pending.removeAll { $0.id == pending.id }
                onConversationChange?(id, false)
                handle(error, context: "Sending message")
                onSendFailed?(id, text, outgoing)
            }
        }
    }

    /// Inserts a message produced locally (demo mode).
    func insertLocal(_ m: Message, chatId: String) {
        conversation(chatId).upsert(m)
        chatsById[chatId]?.applyMessage(m)
        rebuildList()
        onConversationChange?(chatId, false)
    }

    func loadDemo(chats list: [Chat], conversations convs: [String: Conversation], me: String, name: String) {
        demoUser = (me, name)
        for c in list { chatsById[c.id] = c }
        conversations = convs
        rebuildList()
    }

    func isVisible(_ id: String) -> Bool {
        NSApp.isActive && isWindowVisible() && currentChatId == id
    }

    func markReadIfVisible(_ id: String) {
        if isVisible(id) { markRead(id) }
    }

    func markRead(_ id: String) {
        guard let chat = chatsById[id], chat.isUnread(me: me) else { return }
        chat.lastReadAt = max(Date(), (chat.lastMessageAt ?? Date()).addingTimeInterval(0.001))
        notifier.clear(chatId: id)
        onChatsChange?()
        updateBadge()
        guard !demo, let s = auth.session else { return }
        Task {
            do {
                try await graph.send("POST", graph.url("/chats/\(id)/markChatReadForUser"),
                                     json: ["user": ["id": s.userId, "tenantId": s.tenantId]])
            } catch {
                log.error("markChatReadForUser failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func openInTeams(_ id: String? = nil) {
        guard let id = id ?? currentChatId, let link = chatsById[id]?.webUrl, let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    func openImage(_ src: String) {
        Task {
            do { try await images.openFull(src) } catch { handle(error, context: "Opening image") }
        }
    }

    // MARK: - Presence ("always Available")

    /// Keeps an app presence session at Available (4 h expiry, renewed hourly) and sets the
    /// preferred presence to Available, so Teams shows you online while TeamsLite runs.
    func updatePresence() async {
        presenceTimer?.invalidate()
        presenceTimer = nil
        guard signedIn, !demo, Config.alwaysAvailable, let s = auth.session else {
            presence = .off
            onStatusChange?()
            return
        }
        do {
            try await graph.send("POST", graph.url("/users/\(s.userId)/presence/setPresence"), json: [
                "sessionId": Config.clientID, "availability": "Available", "activity": "Available", "expirationDuration": "PT4H",
            ], presence: true)
            try await graph.send("POST", graph.url("/users/\(s.userId)/presence/setUserPreferredPresence"), json: [
                "availability": "Available", "activity": "Available",
            ], presence: true)
            presence = .available
            schedulePresence(after: 60 * 60)
        } catch AuthError.notSignedIn {
            presence = .off
        } catch let e as AuthError {
            // Token request refused for Presence.ReadWrite: consent missing (AADSTS65001 and similar).
            log.info("Presence needs consent: \(e.localizedDescription, privacy: .public)")
            presence = .needsConsent
            onPresenceNeedsConsent?()
        } catch let e as GraphError where e.status == 403 {
            presence = .needsConsent
            onPresenceNeedsConsent?()
        } catch {
            log.error("Presence update failed: \(error.localizedDescription, privacy: .public)")
            presence = .failed(Self.describe(error))
            schedulePresence(after: 5 * 60)
        }
        onStatusChange?()
    }

    /// One-time browser consent for Presence.ReadWrite (same account, chats stay as they are).
    func grantPresence() async throws {
        try await auth.signInWithBrowser(loginHint: username, extraScopes: "Presence.ReadWrite")
        await updatePresence()
    }

    func presenceSettingChanged() {
        Task {
            if Config.alwaysAvailable { await updatePresence() } else { await clearPresence(); onStatusChange?() }
        }
    }

    private func clearPresence() async {
        presenceTimer?.invalidate()
        presenceTimer = nil
        guard presence == .available, let s = auth.session else { presence = .off; return }
        _ = try? await graph.send("POST", graph.url("/users/\(s.userId)/presence/clearPresence"),
                                  json: ["sessionId": Config.clientID], presence: true)
        _ = try? await graph.send("POST", graph.url("/users/\(s.userId)/presence/clearUserPreferredPresence"),
                                  json: [String: Any](), presence: true)
        presence = .off
    }

    private func schedulePresence(after seconds: TimeInterval) {
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.updatePresence() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        presenceTimer = timer
    }

    // MARK: - People

    func searchUsers(_ query: String) async throws -> [UserDTO] {
        if demo { return DemoData.people.filter { ($0.displayName ?? "").localizedCaseInsensitiveContains(query) } }
        let q = query.replacingOccurrences(of: "'", with: "''")
        let filter = ["displayName", "givenName", "surname", "mail", "userPrincipalName"]
            .map { "startswith(\($0),'\(q)')" }
            .joined(separator: " or ")
        let page = try await graph.get(Page<UserDTO>.self, "/users", [
            ("$filter", filter),
            ("$select", "id,displayName,mail,userPrincipalName"),
            ("$top", "20"),
        ])
        return page.value.filter { $0.id != me }
    }

    /// Opens (or creates) the 1:1 chat with a person and returns its id.
    func chatWith(_ user: UserDTO) async throws -> String {
        if let existing = chatsById.values.first(where: {
            $0.chatType == "oneOnOne" && $0.members.count == 1 && $0.members[0].id == user.id
        }) {
            existing.hidden = false
            return existing.id
        }
        if demo { throw GraphError.http(0, "Not available in demo mode.") }
        func member(_ id: String) -> [String: Any] {
            ["@odata.type": "#microsoft.graph.aadUserConversationMember",
             "roles": ["owner"],
             "user@odata.bind": "https://graph.microsoft.com/v1.0/users('\(id)')"]
        }
        let data = try await graph.send("POST", graph.url("/chats"), json: [
            "chatType": "oneOnOne",
            "members": [member(me), member(user.id)],
        ])
        let dto = try await Graph.decode(ChatDTO.self, data)
        let chat = chatsById[dto.id] ?? Chat(id: dto.id)
        chatsById[dto.id] = chat
        chat.update(from: dto, me: me)
        chat.hidden = false
        if chat.members.isEmpty {
            chat.members = [Member(id: user.id, name: user.displayName ?? user.mail ?? "", email: user.mail)]
            chat.membersLoaded = true
        }
        if chat.createdAt == nil { chat.createdAt = Date() }
        rebuildList()
        return dto.id
    }

    // MARK: - Live updates (relay + Graph subscription)

    private func connectRelay() {
        guard let base = Config.relayURL, let s = auth.session else {
            onStatusChange?()
            return
        }
        relay.connect(base.appendingPathComponent("ws").appendingPathComponent(s.roomId))
    }

    private func relayConnected(outage: TimeInterval?) {
        Task {
            await ensureSubscription()
            if let outage, outage > 10 {
                await refreshChats()
                if let id = currentChatId { await loadLatest(id) }
            }
        }
    }

    /// Creates or renews the subscription on /users/{id}/chats/getAllMessages.
    /// It expires after 55 minutes; renewal runs every 40 minutes while the app is running.
    func ensureSubscription() async {
        guard !demo, let base = Config.relayURL, let s = auth.session else { return }
        let defaults = UserDefaults.standard
        let expiry = GraphDate.string(Date().addingTimeInterval(55 * 60))
        let binding = s.roomId + "|" + base.absoluteString

        if let id = defaults.string(forKey: "subscriptionId"), defaults.string(forKey: "subscriptionBinding") == binding {
            do {
                try await graph.send("PATCH", graph.url("/subscriptions/\(id)", beta: defaults.bool(forKey: "subscriptionBeta")),
                                     json: ["expirationDateTime": expiry])
                subscriptionOK()
                return
            } catch let e as GraphError where ![401, 429, 500, 502, 503, 504].contains(e.status) {
                // Expired or removed: create a fresh one below.
                log.info("Subscription renewal rejected (\(e.status)); creating a new one")
                defaults.removeObject(forKey: "subscriptionId")
            } catch {
                subscriptionFailed(error)
                return
            }
        }

        let notifyURL = base.appendingPathComponent("notify").appendingPathComponent(s.roomId).absoluteString
        let body: [String: Any] = [
            "changeType": "created,updated,deleted",
            "notificationUrl": notifyURL,
            "lifecycleNotificationUrl": notifyURL,
            "resource": "/users/\(s.userId)/chats/getAllMessages",
            "includeResourceData": false,
            "expirationDateTime": expiry,
            "clientState": s.clientState,
        ]
        for beta in [false, true] {
            do {
                let data = try await graph.send("POST", graph.url("/subscriptions", beta: beta), json: body)
                let sub = try await Graph.decode(SubscriptionDTO.self, data)
                defaults.set(sub.id, forKey: "subscriptionId")
                defaults.set(beta, forKey: "subscriptionBeta")
                defaults.set(binding, forKey: "subscriptionBinding")
                log.info("Graph subscription created (\(beta ? "beta" : "v1.0", privacy: .public))")
                subscriptionOK()
                return
            } catch let e as GraphError where e.status == 400 && !beta {
                log.info("v1.0 subscription rejected (\(e.localizedDescription, privacy: .public)), trying beta")
            } catch {
                subscriptionFailed(error)
                return
            }
        }
    }

    private func subscriptionOK() {
        subscriptionError = nil
        errorText = nil
        renewRetry = 60
        scheduleRenewal(after: 40 * 60)
        onStatusChange?()
    }

    private func subscriptionFailed(_ error: Error) {
        if let e = error as? AuthError, e.needsSignIn {
            handle(error, context: "Subscription")
            return
        }
        log.error("Subscription failed: \(error.localizedDescription, privacy: .public)")
        subscriptionError = "Live updates unavailable: \(Self.describe(error))"
        scheduleRenewal(after: renewRetry)
        renewRetry = min(renewRetry * 2, 30 * 60)
        onStatusChange?()
    }

    private func scheduleRenewal(after seconds: TimeInterval) {
        renewTimer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.ensureSubscription() }
        }
        timer.tolerance = min(60, seconds / 10)
        RunLoop.main.add(timer, forMode: .common)
        renewTimer = timer
    }

    private func handleRelay(_ data: Data) {
        guard let s = auth.session,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["value"] as? [[String: Any]] else { return }
        for n in items {
            guard (n["clientState"] as? String) == s.clientState else { continue }
            if let event = n["lifecycleEvent"] as? String {
                lifecycle(event)
                continue
            }
            guard let resource = n["resource"] as? String, let (chatId, messageId) = Self.parse(resource) else { continue }
            fetchMessage(chatId: chatId, messageId: messageId, change: n["changeType"] as? String ?? "created")
        }
    }

    private func lifecycle(_ event: String) {
        log.info("Subscription lifecycle event: \(event, privacy: .public)")
        switch event {
        case "subscriptionRemoved":
            UserDefaults.standard.removeObject(forKey: "subscriptionId")
            Task { await ensureSubscription() }
        case "reauthorizationRequired":
            Task { await ensureSubscription() }
        case "missed":
            Task {
                await refreshChats()
                if let id = currentChatId { await loadLatest(id) }
            }
        default:
            break
        }
    }

    /// "chats('19:…@thread.v2')/messages('1612289765949')" -> (chat id, message id)
    static func parse(_ resource: String) -> (String, String)? {
        let s = resource.removingPercentEncoding ?? resource
        if let c = s.range(of: "chats('"), let ce = s.range(of: "')", range: c.upperBound..<s.endIndex),
           let m = s.range(of: "messages('", range: ce.upperBound..<s.endIndex),
           let mEnd = s.range(of: "')", range: m.upperBound..<s.endIndex) {
            return (String(s[c.upperBound..<ce.lowerBound]), String(s[m.upperBound..<mEnd.lowerBound]))
        }
        let parts = s.split(separator: "/").map(String.init)
        if let ci = parts.firstIndex(of: "chats"), ci + 3 < parts.count, parts[ci + 2] == "messages" {
            return (parts[ci + 1], parts[ci + 3])
        }
        return nil
    }

    private func fetchMessage(chatId: String, messageId: String, change: String) {
        // Our own sends are already applied from the POST response.
        if change == "created", conversations[chatId]?.contains(messageId) == true { return }
        let key = chatId + "|" + messageId
        guard !fetching.contains(key) else {
            refetch.insert(key)
            return
        }
        fetching.insert(key)
        Task {
            do {
                let dto = try await graph.get(MessageDTO.self, "/chats/\(chatId)/messages/\(messageId)")
                await apply(dto, chatId: chatId, change: change)
            } catch let e as GraphError where e.status == 404 {
                conversations[chatId]?.markDeleted(messageId)
                onConversationChange?(chatId, false)
            } catch {
                handle(error, context: "Fetching message")
            }
            fetching.remove(key)
            if refetch.remove(key) != nil { fetchMessage(chatId: chatId, messageId: messageId, change: "updated") }
        }
    }

    private func apply(_ dto: MessageDTO, chatId: String, change: String) async {
        guard let m = Message(dto) else { return }
        let chat: Chat
        if let known = chatsById[chatId] {
            chat = known
        } else {
            chat = Chat(id: chatId)
            if let info = try? await graph.get(ChatDTO.self, "/chats/\(chatId)", [("$expand", "members")]) {
                chat.update(from: info, me: me)
            }
            chatsById[chatId] = chat
        }
        let isNewest = chat.lastMessageAt.map { m.createdAt >= $0 } ?? true
        chat.applyMessage(m)
        chat.hidden = false
        if let type = dto.eventDetail?.type?.lowercased() {
            if type.contains("chatrenamed") { chat.topic = dto.eventDetail?.chatDisplayName }
            if type.contains("members") { await loadMembers(chat) }
        }
        if let conv = conversations[chatId], conv.loaded {
            conv.upsert(m)
            onConversationChange?(chatId, false)
        }
        rebuildList()
        guard change == "created", m.kind == .user, m.senderId != me, isNewest else { return }
        if isVisible(chatId) {
            markRead(chatId)
        } else {
            notify(chat, sender: m.senderName, text: m.deleted ? "" : Preview.messageText(m))
        }
    }

    private func notify(_ chat: Chat, sender: String?, text: String) {
        let name = title(of: chat)
        if chat.chatType == "oneOnOne" {
            notifier.post(chatId: chat.id, title: sender ?? name, subtitle: nil, body: text)
        } else {
            notifier.post(chatId: chat.id, title: name, subtitle: sender, body: text)
        }
    }

    // MARK: - Errors

    private func setError(_ text: String?) {
        guard errorText != text else { return }
        errorText = text
        onStatusChange?()
    }

    private func handle(_ error: Error, context: String) {
        if let e = error as? AuthError, e.needsSignIn {
            reset(notice: "Your session expired. Please sign in again.")
            return
        }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        log.error("\(context, privacy: .public): \(error.localizedDescription, privacy: .public)")
        setError(Self.describe(error))
    }

    static func describe(_ error: Error) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed:
                return "Offline"
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
