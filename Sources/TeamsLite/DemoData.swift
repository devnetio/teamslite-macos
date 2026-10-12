import AppKit

/// Offline sample data for `--demo`: exercises the UI and renderer without signing in.
@MainActor
enum DemoData {
    static let me = "00000000-0000-0000-0000-000000000001"

    static let people: [UserDTO] = [
        UserDTO(id: "u-ana", displayName: "Ana Petrović", mail: "ana@example.com", userPrincipalName: nil),
        UserDTO(id: "u-ivan", displayName: "Ivan Jovanović", mail: "ivan@example.com", userPrincipalName: nil),
        UserDTO(id: "u-mila", displayName: "Mila Nikolić", mail: "mila@example.com", userPrincipalName: nil),
    ]

    static func load(into model: AppModel) {
        let now = Date()
        func ago(_ minutes: Double) -> String { GraphDate.string(now.addingTimeInterval(-minutes * 60)) }

        func msg(_ id: String, _ from: String?, _ name: String, _ minutes: Double, _ html: String,
                 type: String = "message", reactions: [(String, String)] = [], attachments: [AttachmentDTO] = [],
                 edited: Bool = false, deleted: Bool = false, event: EventDetailDTO? = nil) -> Message {
            let dto = MessageDTO(
                id: id, messageType: type, createdDateTime: ago(minutes), lastModifiedDateTime: ago(minutes),
                lastEditedDateTime: edited ? ago(minutes - 1) : nil, deletedDateTime: deleted ? ago(minutes - 1) : nil,
                importance: "normal", subject: nil,
                from: from.map { FromDTO(user: IdentityDTO(id: $0, displayName: name), application: nil) },
                body: BodyDTO(contentType: "html", content: html), attachments: attachments,
                reactions: reactions.map { ReactionDTO(reactionType: $0.0, user: FromDTO(user: IdentityDTO(id: $0.1, displayName: nil), application: nil)) },
                eventDetail: event)
            return Message(dto)!
        }

        func chat(_ id: String, topic: String?, type: String, members: [(String, String)], readMinutesAgo: Double) -> Chat {
            let c = Chat(id: id)
            c.topic = topic
            c.chatType = type
            c.webUrl = "https://teams.microsoft.com/"
            c.members = members.map { Member(id: $0.0, name: $0.1, email: $0.0.replacingOccurrences(of: "u-", with: "") + "@example.com") }
            c.membersLoaded = true
            c.lastReadAt = now.addingTimeInterval(-readMinutesAgo * 60)
            return c
        }

        let ana = chat("c-ana", topic: nil, type: "oneOnOne", members: [("u-ana", "Ana Petrović")], readMinutesAgo: 30)
        let team = chat("c-team", topic: "Webshop team", type: "group",
                        members: [("u-ivan", "Ivan Jovanović"), ("u-mila", "Mila Nikolić"), ("u-ana", "Ana Petrović")], readMinutesAgo: 1)
        let ivan = chat("c-ivan", topic: nil, type: "oneOnOne", members: [("u-ivan", "Ivan Jovanović")], readMinutesAgo: 0)
        let standup = chat("c-meet", topic: "Daily stand-up", type: "meeting", members: [("u-mila", "Mila Nikolić")], readMinutesAgo: 0)

        let reply = AttachmentDTO(id: "a1", contentType: "messageReference", contentUrl: nil,
                                  content: #"{"messageId":"t2","messagePreview":"Can someone check the order export?","messageSender":{"user":{"displayName":"Ivan Jovanović"}}}"#,
                                  name: nil)
        let file = AttachmentDTO(id: "a2", contentType: "reference", contentUrl: "https://example.com/report.xlsx",
                                 content: nil, name: "Sales report Q3.xlsx")
        let card = AttachmentDTO(id: "a3", contentType: "application/vnd.microsoft.card.adaptive", contentUrl: nil,
                                 content: #"{"type":"AdaptiveCard","body":[{"type":"TextBlock","text":"Build 2481 succeeded"},{"type":"FactSet","facts":[{"title":"Pipeline:","value":"Webshop CI"},{"title":"Duration:","value":"6m 12s"}]}]}"#,
                                 name: nil)

        let anaConv = Conversation()
        for m in [
            msg("a1", "u-ana", "Ana Petrović", 180, "<p>Hi! Do you have a minute today? 🙂</p>"),
            msg("a2", me, "Alex", 175, "<p>Sure, after 2 pm works for me.</p>"),
            msg("a3", "u-ana", "Ana Petrović", 12, "<p>Great. Here is the <a href=\"https://example.com/spec\">updated spec</a>.</p><ul><li>New checkout flow</li><li>Payment provider <b>retries</b></li></ul>",
                reactions: [("like", me)]),
            msg("a4", "u-ana", "Ana Petrović", 11, "<p>Can you review it before the meeting?</p>"),
        ] { anaConv.upsert(m) }
        anaConv.loaded = true

        let teamConv = Conversation()
        for m in [
            msg("t1", nil, "", 300, "<systemEventMessage/>", type: "systemEventMessage",
                event: EventDetailDTO(type: "#microsoft.graph.membersAddedEventMessageDetail", chatDisplayName: nil, callDuration: nil,
                                      members: [IdentityDTO(id: "u-mila", displayName: "Mila Nikolić")])),
            msg("t2", "u-ivan", "Ivan Jovanović", 95, "<p>Can someone check the order export? The CSV has an extra column since yesterday.</p>"),
            msg("t3", "u-mila", "Mila Nikolić", 90, "<p>On it. Looks like the <code>ExportService</code> picks up the new field:</p><pre>SELECT Id, Total, Currency\nFROM Orders</pre>",
                attachments: [reply], edited: true),
            msg("t4", "u-ivan", "Ivan Jovanović", 88, "<p>Thanks <at id=\"0\">Mila</at>! 🙏</p>", reactions: [("heart", "u-mila"), ("like", me), ("like", "u-ana")]),
            msg("t5", nil, "", 60, "<systemEventMessage/>", type: "systemEventMessage",
                event: EventDetailDTO(type: "#microsoft.graph.callEndedEventMessageDetail", chatDisplayName: nil, callDuration: "PT14M5S", members: nil)),
            msg("t6", "u-ana", "Ana Petrović", 40, "<p>Report attached.</p>", attachments: [file]),
            msg("t7", "u-ivan", "Ivan Jovanović", 39, "", deleted: true),
            msg("t8", "bot", "Azure DevOps", 5, "<attachment id=\"a3\"></attachment>", attachments: [card]),
            msg("t9", "u-mila", "Mila Nikolić", 3, "<p>Here is the error from checkout:</p><p><img src=\"https://demo.invalid/screenshot.png\" width=\"640\" height=\"360\" alt=\"image\"></p>"),
            msg("t10", me, "Alex", 2, "<p><img src=\"https://demo.invalid/pending.png\" width=\"300\" height=\"120\"></p>"),
        ] { teamConv.upsert(m) }
        teamConv.loaded = true

        let ivanConv = Conversation()
        for m in [
            msg("i1", me, "Alex", 2900, "<p>Deploy is done ✅</p>"),
            msg("i2", "u-ivan", "Ivan Jovanović", 2890, "<p>👍</p>"),
        ] { ivanConv.upsert(m) }
        ivanConv.loaded = true

        let meetConv = Conversation()
        meetConv.upsert(msg("m1", "u-mila", "Mila Nikolić", 4400, "<p>Notes are in the wiki: https://example.com/wiki/standup</p>"))
        meetConv.loaded = true

        for (c, conv) in [(ana, anaConv), (team, teamConv), (ivan, ivanConv), (standup, meetConv)] {
            if let last = conv.messages.last { c.applyMessage(last) }
        }
        // A generated "screenshot" so the image path renders without network access.
        let shot = NSImage(size: NSSize(width: 320, height: 180), flipped: false) { rect in
            NSColor.systemIndigo.setFill(); rect.fill()
            NSColor.white.setFill(); NSRect(x: 20, y: 20, width: 280, height: 110).fill()
            ("Payment failed: 502" as NSString).draw(at: NSPoint(x: 34, y: 70), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 20)])
            return true
        }
        model.images.store("https://demo.invalid/screenshot.png", shot)
        model.loadDemo(chats: [ana, team, ivan, standup],
                       conversations: ["c-ana": anaConv, "c-team": teamConv, "c-ivan": ivanConv, "c-meet": meetConv],
                       me: me, name: "Alex Example")
        model.openChat("c-team")
    }

    static func echo(_ text: String, chatId: String, into model: AppModel) {
        let dto = MessageDTO(id: UUID().uuidString, messageType: "message", createdDateTime: GraphDate.string(Date()),
                             lastModifiedDateTime: nil, lastEditedDateTime: nil, deletedDateTime: nil, importance: nil,
                             subject: nil, from: FromDTO(user: IdentityDTO(id: me, displayName: "Alex Example"), application: nil),
                             body: BodyDTO(contentType: "html", content: HTML.fromPlainText(text)),
                             attachments: nil, reactions: nil, eventDetail: nil)
        if let m = Message(dto) { model.insertLocal(m, chatId: chatId) }
    }
}
