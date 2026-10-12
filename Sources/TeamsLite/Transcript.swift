import AppKit

/// Builds the whole conversation as one attributed string for a single NSTextView:
/// far cheaper than a view per message, and text stays selectable across messages.
@MainActor
enum Transcript {
    static let olderLink = URL(string: "teamslite://older")!

    static func imageLink(_ src: String) -> URL {
        var c = URLComponents()
        c.scheme = "teamslite"
        c.host = "image"
        c.queryItems = [URLQueryItem(name: "src", value: src)]
        return c.url!
    }

    static func imageSource(_ url: URL) -> String? {
        guard url.scheme == "teamslite", url.host == "image" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "src" }?.value
    }

    private static let nameFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let metaFont = NSFont.systemFont(ofSize: 11)
    private static let smallFont = NSFont.systemFont(ofSize: 11.5)
    private static let bodyFont = NSFont.systemFont(ofSize: 13)

    private static let reactionEmoji = ["like": "👍", "heart": "❤️", "laugh": "😆",
                                        "surprised": "😮", "sad": "😢", "angry": "😡"]

    static func render(_ conv: Conversation, me: String, images: ImageStore?) -> NSAttributedString {
        let out = NSMutableAttributedString()

        if conv.olderLink != nil {
            out.append(centered("Load earlier messages", color: .linkColor, link: olderLink, spacingAfter: 6))
        } else if conv.loaded, conv.messages.isEmpty, conv.pending.isEmpty {
            out.append(centered("No messages yet — say hello 👋", color: .secondaryLabelColor))
        } else if !conv.loaded, conv.messages.isEmpty {
            out.append(centered("Loading…", color: .secondaryLabelColor))
        }

        var previousDay: Date?
        var previousSender: String?
        var previousTime = Date.distantPast
        let calendar = Calendar.current

        for m in conv.messages {
            let day = calendar.startOfDay(for: m.createdAt)
            if day != previousDay {
                out.append(centered(Fmt.day(m.createdAt), color: .secondaryLabelColor, font: metaFont,
                                    spacingBefore: out.length > 0 ? 14 : 0, spacingAfter: 2))
                previousDay = day
                previousSender = nil
            }
            if m.kind == .system {
                out.append(centered("\(m.systemText ?? "")  ·  \(Fmt.time.string(from: m.createdAt))",
                                    color: .tertiaryLabelColor, font: metaFont, spacingBefore: 6, spacingAfter: 2))
                previousSender = nil
                continue
            }
            let grouped = m.senderId != nil && m.senderId == previousSender && m.createdAt.timeIntervalSince(previousTime) < 300
            if !grouped { out.append(header(m, me: me)) }
            out.append(cachedBody(m, me: me, in: conv, images: images))
            previousSender = m.senderId
            previousTime = m.createdAt
        }

        for p in conv.pending {
            out.append(line([("You", nameFont, NSColor.controlAccentColor), ("   Sending…", metaFont, NSColor.secondaryLabelColor)],
                            spacingBefore: 10))
            let pics = p.imageCount == 0 ? "" : (p.text.isEmpty ? "" : "\n") + String(repeating: "🖼 ", count: p.imageCount) + "Image"
            out.append(NSAttributedString(string: p.text + pics + "\n",
                                          attributes: [.font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor,
                                                       .paragraphStyle: bodyStyle]))
        }

        if out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    // MARK: Pieces

    private static func header(_ m: Message, me: String) -> NSAttributedString {
        let mine = m.senderId == me
        var parts: [(String, NSFont, NSColor)] = [(mine ? "You" : m.senderName, nameFont, mine ? .controlAccentColor : .labelColor),
                                                   ("   " + Fmt.time.string(from: m.createdAt), metaFont, .secondaryLabelColor)]
        if m.edited, !m.deleted { parts.append(("  · edited", metaFont, .tertiaryLabelColor)) }
        switch m.importance {
        case "urgent": parts.append(("   🚨 Urgent", metaFont, .systemRed))
        case "high": parts.append(("   ❗ Important", metaFont, .systemRed))
        default: break
        }
        return line(parts, spacingBefore: 10)
    }

    /// Bodies with images are never cached: the cache would pin thumbnails beyond ImageStore's cap.
    private static func cachedBody(_ m: Message, me: String, in conv: Conversation, images: ImageStore?) -> NSAttributedString {
        if let (stamp, cached) = conv.renderCache[m.id], stamp == m.modifiedAt { return cached }
        let (rendered, hasImages) = body(m, me: me, images: images)
        if !hasImages { conv.renderCache[m.id] = (m.modifiedAt, rendered) }
        return rendered
    }

    private static func body(_ m: Message, me: String, images: ImageStore?) -> (NSAttributedString, Bool) {
        let out = NSMutableAttributedString()
        if m.deleted {
            out.append(NSAttributedString(string: "This message was deleted.\n", attributes: [
                .font: NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask),
                .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: bodyStyle]))
            return (out, false)
        }

        // Quoted replies first, like Teams shows them.
        for a in m.attachments where a.contentType == "messageReference" {
            out.append(quote(a))
        }
        if let subject = m.subject, !subject.isEmpty {
            out.append(NSAttributedString(string: subject + "\n", attributes: [.font: nameFont, .foregroundColor: NSColor.labelColor,
                                                                               .paragraphStyle: bodyStyle]))
        }

        let content = m.body?.content ?? ""
        let text: NSMutableAttributedString = (m.body?.contentType ?? "html") == "html"
            ? HTML.attributed(content)
            : NSMutableAttributedString(string: content.trimmingCharacters(in: .whitespacesAndNewlines),
                                        attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor])
        var hasImages = false
        if text.length > 0 {
            text.append(NSAttributedString(string: "\n"))
            applyBodyStyle(text)
            hasImages = attachImages(text, store: images)
            out.append(text)
        }

        for a in m.attachments where a.contentType != "messageReference" {
            out.append(attachment(a))
        }
        if !m.reactions.isEmpty { out.append(reactions(m.reactions, me: me)) }
        return (out, hasImages)
    }

    /// Replaces image placeholders with thumbnails (or a sized placeholder while loading).
    private static func attachImages(_ s: NSMutableAttributedString, store: ImageStore?) -> Bool {
        var refs: [(NSRange, ImageRef)] = []
        s.enumerateAttribute(.teamsLiteImage, in: NSRange(location: 0, length: s.length)) { value, range, _ in
            if let ref = value as? ImageRef { refs.append((range, ref)) }
        }
        for (range, ref) in refs.reversed() {
            let image = store?.image(ref.src)
            let size = ref.displaySize(for: image)
            let attachment = NSTextAttachment()
            if let image {
                attachment.image = image
            } else {
                let failed = store?.hasFailed(ref.src) ?? true
                attachment.image = placeholder(size, text: failed ? "Image unavailable — click to open" : "Loading image…")
                if !failed { store?.request(ref.src) }
            }
            attachment.bounds = CGRect(origin: .zero, size: size)
            let piece = NSMutableAttributedString(attachment: attachment)
            piece.addAttributes([.link: imageLink(ref.src), .paragraphStyle: bodyStyle], range: NSRange(location: 0, length: piece.length))
            s.replaceCharacters(in: range, with: piece)
        }
        return !refs.isEmpty
    }

    private static func placeholder(_ size: NSSize, text: String) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: NSColor.secondaryLabelColor]
            let t = text as NSString
            let ts = t.size(withAttributes: attrs)
            t.draw(at: NSPoint(x: max(4, (rect.width - ts.width) / 2), y: (rect.height - ts.height) / 2), withAttributes: attrs)
            return true
        }
    }

    private static func quote(_ a: AttachmentDTO) -> NSAttributedString {
        var who = "", preview = ""
        if let data = a.content?.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            preview = HTML.collapse(obj["messagePreview"] as? String ?? "")
            let sender = obj["messageSender"] as? [String: Any]
            let user = (sender?["user"] ?? sender?["application"]) as? [String: Any]
            who = user?["displayName"] as? String ?? ""
        }
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = 10
        p.headIndent = 10
        p.paragraphSpacing = 2
        let s = NSMutableAttributedString(string: "↩︎ ", attributes: [.font: smallFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: p])
        if !who.isEmpty {
            s.append(NSAttributedString(string: who + ": ", attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                                                                         .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p]))
        }
        s.append(NSAttributedString(string: String(preview.prefix(240)) + "\n",
                                    attributes: [.font: smallFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p]))
        return s
    }

    private static func attachment(_ a: AttachmentDTO) -> NSAttributedString {
        let type = a.contentType ?? ""
        var attrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: NSColor.secondaryLabelColor,
                                                    .paragraphStyle: bodyStyle]
        if type == "reference" || a.contentUrl != nil, !type.hasPrefix("application/vnd.microsoft.card") {
            if let s = a.contentUrl, let url = HTML.safeURL(s) { attrs[.link] = url }
            return NSAttributedString(string: "📎 " + (a.name ?? "Attachment") + "\n", attributes: attrs)
        }
        if type.contains("card") {
            let text = Preview.cardText(a.content)
            return NSAttributedString(string: "🗂 " + (text.isEmpty ? "Card" : text) + "\n", attributes: attrs)
        }
        if type == "forwardedMessageReference" {
            return NSAttributedString(string: "↪︎ Forwarded message\n", attributes: attrs)
        }
        return NSAttributedString(string: "📎 " + (a.name ?? "Attachment") + "\n", attributes: attrs)
    }

    private static func reactions(_ list: [ReactionDTO], me: String) -> NSAttributedString {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var mine: Set<String> = []
        for r in list {
            let raw = r.reactionType ?? ""
            let emoji = reactionEmoji[raw.lowercased()] ?? raw
            guard !emoji.isEmpty else { continue }
            if counts[emoji] == nil { order.append(emoji) }
            counts[emoji, default: 0] += 1
            if r.user?.user?.id == me { mine.insert(emoji) }
        }
        let out = NSMutableAttributedString()
        for (i, e) in order.enumerated() {
            out.append(NSAttributedString(string: (i > 0 ? "   " : "") + "\(e) \(counts[e] ?? 0)", attributes: [
                .font: smallFont, .paragraphStyle: bodyStyle,
                .foregroundColor: mine.contains(e) ? NSColor.controlAccentColor : NSColor.secondaryLabelColor]))
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: smallFont]))
        return out
    }

    // MARK: Formatting helpers

    private static let bodyStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = 2
        p.lineSpacing = 1
        return p
    }()

    /// Adds the default paragraph style where the HTML converter didn't set one (quotes, lists).
    private static func applyBodyStyle(_ s: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: s.length)
        var plainRanges: [NSRange] = []
        s.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            if value == nil { plainRanges.append(range) }
        }
        for r in plainRanges { s.addAttribute(.paragraphStyle, value: bodyStyle, range: r) }
    }

    private static func line(_ parts: [(String, NSFont, NSColor)], spacingBefore: CGFloat) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = spacingBefore
        p.paragraphSpacing = 1
        let s = NSMutableAttributedString()
        for (text, font, color) in parts {
            s.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p]))
        }
        s.append(NSAttributedString(string: "\n", attributes: [.font: metaFont, .paragraphStyle: p]))
        return s
    }

    private static func centered(_ text: String, color: NSColor, font customFont: NSFont? = nil, link: URL? = nil,
                                 spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 4) -> NSAttributedString {
        let font = customFont ?? smallFont
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.paragraphSpacingBefore = spacingBefore
        p.paragraphSpacing = spacingAfter
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p]
        if let link { attrs[.link] = link }
        let s = NSMutableAttributedString(string: text, attributes: attrs)
        s.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: p]))
        return s
    }
}
