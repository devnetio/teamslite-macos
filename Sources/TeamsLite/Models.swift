import Foundation

// MARK: - Graph payloads (only the fields TeamsLite uses)

struct Page<T: Decodable>: Decodable {
    let value: [T]
    let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

struct IdentityDTO: Decodable {
    let id: String?
    let displayName: String?
}

struct FromDTO: Decodable {
    let user: IdentityDTO?
    let application: IdentityDTO?
}

struct BodyDTO: Decodable {
    let contentType: String?
    let content: String?
}

struct EventDetailDTO: Decodable {
    let type: String?
    let chatDisplayName: String?
    let callDuration: String?
    let members: [IdentityDTO]?

    enum CodingKeys: String, CodingKey {
        case type = "@odata.type"
        case chatDisplayName, callDuration, members
    }
}

struct PreviewDTO: Decodable {
    let id: String?
    let createdDateTime: String?
    let isDeleted: Bool?
    let messageType: String?
    let body: BodyDTO?
    let from: FromDTO?
    let eventDetail: EventDetailDTO?
}

struct MemberDTO: Decodable {
    let displayName: String?
    let userId: String?
    let email: String?
}

struct ChatDTO: Decodable {
    struct Viewpoint: Decodable {
        let isHidden: Bool?
        let lastMessageReadDateTime: String?
    }

    let id: String
    let topic: String?
    let chatType: String?
    let webUrl: String?
    let createdDateTime: String?
    let lastUpdatedDateTime: String?
    let viewpoint: Viewpoint?
    let lastMessagePreview: PreviewDTO?
    let members: [MemberDTO]?
}

struct AttachmentDTO: Decodable {
    let id: String?
    let contentType: String?
    let contentUrl: String?
    let content: String?
    let name: String?
}

struct ReactionDTO: Decodable {
    let reactionType: String?
    let user: FromDTO?
}

struct MessageDTO: Decodable {
    let id: String
    let messageType: String?
    let createdDateTime: String?
    let lastModifiedDateTime: String?
    let lastEditedDateTime: String?
    let deletedDateTime: String?
    let importance: String?
    let subject: String?
    let from: FromDTO?
    let body: BodyDTO?
    let attachments: [AttachmentDTO]?
    let reactions: [ReactionDTO]?
    let eventDetail: EventDetailDTO?
}

struct UserDTO: Decodable {
    let id: String
    let displayName: String?
    let mail: String?
    let userPrincipalName: String?
}

struct SubscriptionDTO: Decodable {
    let id: String
}

// MARK: - App state

struct Member {
    let id: String
    let name: String
    let email: String?
}

final class Chat {
    let id: String
    var topic: String?
    var chatType = "oneOnOne"
    var webUrl: String?
    var hidden = false
    var createdAt: Date?
    var members: [Member] = []      // everyone except the signed-in user
    var membersLoaded = false
    var lastMessageId: String?
    var lastMessageAt: Date?
    var lastSenderId: String?
    var lastSenderName: String?
    var lastIsUserMessage = false
    var lastPreview = ""
    var lastReadAt: Date?

    init(id: String) {
        self.id = id
    }

    var sortDate: Date { lastMessageAt ?? createdAt ?? .distantPast }

    var needsMemberNames: Bool { !membersLoaded && (topic ?? "").trimmingCharacters(in: .whitespaces).isEmpty }

    func isUnread(me: String) -> Bool {
        guard lastIsUserMessage, let at = lastMessageAt, lastSenderId != me else { return false }
        return at > (lastReadAt ?? .distantPast)
    }

    func title(me: String, myName: String) -> String {
        if let t = topic?.trimmingCharacters(in: .whitespaces), !t.isEmpty { return t }
        let names = members.map(\.name).filter { !$0.isEmpty }
        if !names.isEmpty {
            if names.count == 1 { return names[0] }
            let firsts = names.prefix(4).map { $0.split(separator: " ").first.map(String.init) ?? $0 }
            let extra = names.count > 4 ? " +\(names.count - 4)" : ""
            return firsts.joined(separator: ", ") + extra
        }
        if membersLoaded { return myName.isEmpty ? "You" : "\(myName) (You)" }
        if let n = lastSenderName, !n.isEmpty, lastSenderId != me { return n }
        return chatType == "meeting" ? "Meeting chat" : "Chat"
    }

    func subtitle() -> String {
        switch chatType {
        case "meeting": return "Meeting chat"
        case "group": return members.isEmpty ? "Group chat" : "Group chat · \(members.count + 1) people"
        default: return members.first?.email ?? ""
        }
    }

    func update(from dto: ChatDTO, me: String) {
        topic = dto.topic
        if let t = dto.chatType { chatType = t }
        if let u = dto.webUrl { webUrl = u }
        hidden = dto.viewpoint?.isHidden ?? false
        if createdAt == nil { createdAt = GraphDate.parse(dto.createdDateTime) }
        if let read = GraphDate.parse(dto.viewpoint?.lastMessageReadDateTime) {
            lastReadAt = max(read, lastReadAt ?? read)
        }
        if let p = dto.lastMessagePreview { applyPreview(p, me: me) }
        if let m = dto.members { setMembers(m, me: me) }
    }

    func setMembers(_ list: [MemberDTO], me: String) {
        members = list.compactMap { m in
            guard let id = m.userId, id != me else { return nil }
            return Member(id: id, name: m.displayName ?? m.email ?? "Unknown", email: m.email)
        }
        membersLoaded = true
    }

    private func setLast(id: String?, at: Date, senderId: String?, senderName: String?, isUser: Bool, preview: String) {
        if let cur = lastMessageAt, at < cur { return }
        lastMessageId = id
        lastMessageAt = at
        lastSenderId = senderId
        lastSenderName = senderName
        lastIsUserMessage = isUser
        lastPreview = preview
    }

    func applyPreview(_ p: PreviewDTO, me: String) {
        guard let at = GraphDate.parse(p.createdDateTime) else { return }
        let isUser = (p.messageType ?? "message") == "message"
        let text: String
        if !isUser {
            text = Preview.systemText(p.eventDetail) ?? ""
        } else if p.isDeleted == true {
            text = "Message deleted"
        } else {
            text = Preview.bodyText(p.body)
        }
        setLast(id: p.id, at: at, senderId: p.from?.user?.id ?? p.from?.application?.id,
                senderName: p.from?.user?.displayName ?? p.from?.application?.displayName,
                isUser: isUser, preview: text)
    }

    func applyMessage(_ m: Message) {
        let text: String
        switch m.kind {
        case .system: text = m.systemText ?? ""
        case .user: text = m.deleted ? "Message deleted" : Preview.messageText(m)
        }
        setLast(id: m.id, at: m.createdAt, senderId: m.senderId, senderName: m.senderName,
                isUser: m.kind == .user, preview: text)
    }
}

struct Message {
    enum Kind { case user, system }

    let id: String
    let kind: Kind
    let createdAt: Date
    let modifiedAt: Date
    let edited: Bool
    let deleted: Bool
    let senderId: String?
    let senderName: String
    let body: BodyDTO?
    let attachments: [AttachmentDTO]
    let reactions: [ReactionDTO]
    let importance: String?
    let subject: String?
    let systemText: String?

    /// Returns nil for message types TeamsLite doesn't show (typing, unknown events, ...).
    init?(_ d: MessageDTO) {
        guard let created = GraphDate.parse(d.createdDateTime) else { return nil }
        switch d.messageType ?? "message" {
        case "message":
            kind = .user
            systemText = nil
        case "systemEventMessage":
            guard let text = Preview.systemText(d.eventDetail) else { return nil }
            kind = .system
            systemText = text
        default:
            return nil
        }
        id = d.id
        createdAt = created
        modifiedAt = GraphDate.parse(d.lastModifiedDateTime) ?? created
        edited = d.lastEditedDateTime != nil
        deleted = d.deletedDateTime != nil
        senderId = d.from?.user?.id ?? d.from?.application?.id
        senderName = d.from?.user?.displayName ?? d.from?.application?.displayName ?? "Unknown"
        body = d.body
        attachments = d.attachments ?? []
        reactions = d.reactions ?? []
        importance = d.importance
        subject = d.subject
    }
}

/// Unsent message shown in the transcript until Graph confirms it.
struct PendingMessage {
    let id = UUID().uuidString
    let text: String
    var imageCount = 0
}

/// Loaded messages of one chat (ascending by creation time) plus render cache.
final class Conversation {
    private(set) var messages: [Message] = []
    var olderLink: String?
    var loaded = false
    var loading = false
    var pending: [PendingMessage] = []
    var renderCache: [String: (Date, NSAttributedString)] = [:]

    func contains(_ id: String) -> Bool { messages.contains { $0.id == id } }

    func upsert(_ m: Message) {
        if let i = messages.firstIndex(where: { $0.id == m.id }) {
            messages[i] = m
            return
        }
        var lo = 0, hi = messages.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if messages[mid].createdAt <= m.createdAt { lo = mid + 1 } else { hi = mid }
        }
        messages.insert(m, at: lo)
    }

    func markDeleted(_ id: String) {
        messages.removeAll { $0.id == id }
        renderCache[id] = nil
    }
}

// MARK: - Text helpers

enum Preview {
    /// Preview of a full message: body text, else card text or file name.
    static func messageText(_ m: Message) -> String {
        let raw = m.body?.content ?? ""
        let text = (m.body?.contentType ?? "html") == "html" ? HTML.plainText(raw) : HTML.collapse(raw)
        if !text.isEmpty { return String(text.prefix(200)) }
        for a in m.attachments {
            let type = a.contentType ?? ""
            if type.contains("card"), let line = cardText(a.content).split(separator: "\n").first {
                return "🗂 " + line
            }
            if type == "reference" { return "📎 " + (a.name ?? "Attachment") }
        }
        return bodyText(m.body)
    }

    static func bodyText(_ body: BodyDTO?) -> String {
        let raw = body?.content ?? ""
        let text = (body?.contentType ?? "html") == "html" ? HTML.plainText(raw) : HTML.collapse(raw)
        if !text.isEmpty { return String(text.prefix(200)) }
        if raw.contains("<attachment") { return "📎 Attachment" }
        if raw.contains("<img") { return "🖼 Image" }
        return ""
    }

    static func systemText(_ d: EventDetailDTO?) -> String? {
        guard let type = d?.type?.lowercased() else { return nil }
        let names = (d?.members ?? []).compactMap { $0.displayName }.filter { !$0.isEmpty }
        let who = names.isEmpty ? "Members" : names.joined(separator: ", ")
        switch type {
        case "#microsoft.graph.callstartedeventmessagedetail": return "📞 Call started"
        case "#microsoft.graph.callendedeventmessagedetail":
            return "📞 Call ended" + (duration(d?.callDuration).map { " · \($0)" } ?? "")
        case "#microsoft.graph.callrecordingeventmessagedetail": return "⏺ Call recording available"
        case "#microsoft.graph.membersaddedeventmessagedetail": return "➕ \(who) added"
        case "#microsoft.graph.membersjoinedeventmessagedetail": return "➕ \(who) joined"
        case "#microsoft.graph.membersdeletedeventmessagedetail": return "➖ \(who) removed"
        case "#microsoft.graph.memberslefteventmessagedetail": return "➖ \(who) left"
        case "#microsoft.graph.chatrenamedeventmessagedetail":
            return "✏️ Chat renamed to “\(d?.chatDisplayName ?? "")”"
        case "#microsoft.graph.messagepinnedeventmessagedetail": return "📌 Message pinned"
        default: return nil
        }
    }

    /// "PT1H2M10S" -> "1h 2m 10s"
    static func duration(_ iso: String?) -> String? {
        guard let iso, iso.hasPrefix("PT") else { return nil }
        var out: [String] = []
        var number = ""
        for ch in iso.dropFirst(2) {
            if ch.isNumber || ch == "." {
                number.append(ch)
            } else if !number.isEmpty {
                let n = Int(Double(number) ?? 0)
                out.append("\(n)\(String(ch).lowercased())")
                number = ""
            }
        }
        return out.isEmpty ? nil : out.joined(separator: " ")
    }

    /// Readable text of Adaptive / Hero / O365 connector cards (bot and connector messages).
    static func cardText(_ json: String?) -> String {
        guard let json, let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return "" }
        var parts: [String] = []
        let textKeys = ["title", "activityTitle", "subtitle", "activitySubtitle", "text", "activityText"]
        let containerKeys = ["body", "items", "columns", "sections", "facts", "content", "card", "inlines"]
        func walk(_ node: Any, _ depth: Int) {
            guard depth < 10, parts.count < 16 else { return }
            if let dict = node as? [String: Any] {
                if let title = dict["title"] as? String, let value = dict["value"] as? String {
                    parts.append("\(title) \(value)")
                } else if let name = dict["name"] as? String, let value = dict["value"] as? String {
                    parts.append("\(name): \(value)")
                } else {
                    for key in textKeys {
                        if let s = dict[key] as? String, !s.isEmpty {
                            parts.append(s.contains("<") ? HTML.plainText(s) : s)
                        }
                    }
                }
                for key in containerKeys { if let sub = dict[key] { walk(sub, depth + 1) } }
            } else if let list = node as? [Any] {
                for item in list { walk(item, depth + 1) }
            }
        }
        walk(root, 0)
        return String(parts.filter { !$0.isEmpty }.joined(separator: "\n").prefix(800))
    }
}
