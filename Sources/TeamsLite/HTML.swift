import AppKit

/// Lightweight Teams-HTML handling. NSAttributedString's own HTML importer loads
/// WebKit, which is exactly the memory TeamsLite avoids, so this is a small
/// tag scanner that understands the subset Teams produces.
enum HTML {
    static func attributed(_ html: String, size: CGFloat = 13) -> NSMutableAttributedString {
        let c = Converter(size: size, plain: false)
        c.run(html)
        let out = c.rich
        linkify(out)
        return out
    }

    /// Single-line text for chat previews and notifications.
    static func plainText(_ html: String) -> String {
        let c = Converter(size: 13, plain: true)
        c.run(html)
        return collapse(c.text).trimmingCharacters(in: .whitespaces)
    }

    /// Outgoing message body: escaped HTML with links and line breaks.
    static func fromPlainText(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in linkDetector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += escape(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            let shown = ns.substring(with: m.range)
            let href = m.url?.absoluteString ?? shown
            out += "<a href=\"\(escape(href))\">\(escape(shown))</a>"
            last = m.range.location + m.range.length
        }
        out += escape(ns.substring(from: last))
        return out.replacingOccurrences(of: "  ", with: " &nbsp;").replacingOccurrences(of: "\n", with: "<br>")
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    static func collapse(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var space = false
        for ch in s {
            if ch.isWhitespace && ch != "\u{00A0}" {
                if !space { out.append(" ") }
                space = true
            } else {
                out.append(ch)
                space = false
            }
        }
        return out
    }

    static let linkDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func safeURL(_ s: String) -> URL? {
        let raw = s.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: raw) ?? URL(string: raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "msteams", "tel"].contains(scheme) else { return nil }
        return url
    }

    /// Turns bare URLs into links (text messages and HTML without anchors).
    private static func linkify(_ s: NSMutableAttributedString) {
        let str = s.string
        guard str.contains("://") || str.contains("www.") else { return }
        for m in linkDetector.matches(in: str, range: NSRange(location: 0, length: s.length)) {
            guard let url = m.url, s.attribute(.link, at: m.range.location, effectiveRange: nil) == nil else { continue }
            s.addAttribute(.link, value: url, range: m.range)
        }
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";"),
               let decoded = entity(s[s.index(after: i)..<semi]) {
                out += decoded
                i = s.index(after: semi)
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }

    private static func entity(_ e: Substring) -> String? {
        if e.first == "#" {
            let digits = e.dropFirst()
            let value = (digits.first == "x" || digits.first == "X") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return named[String(e)]
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "hellip": "…", "laquo": "«", "raquo": "»",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "sbquo": "‚", "bdquo": "„",
        "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™", "euro": "€",
        "pound": "£", "yen": "¥", "cent": "¢", "deg": "°", "plusmn": "±", "times": "×",
        "divide": "÷", "sect": "§", "para": "¶", "shy": "", "zwj": "\u{200D}", "zwnj": "\u{200C}",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "check": "✓",
    ]

    static func attributes(_ s: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var i = s.startIndex
        func skipSpace() { while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) } }
        while true {
            skipSpace()
            guard i < s.endIndex else { break }
            let start = i
            while i < s.endIndex, !s[i].isWhitespace, s[i] != "=", s[i] != "/" { i = s.index(after: i) }
            let name = s[start..<i].lowercased()
            if name.isEmpty {
                i = s.index(after: i)
                continue
            }
            skipSpace()
            var value = ""
            if i < s.endIndex, s[i] == "=" {
                i = s.index(after: i)
                skipSpace()
                if i < s.endIndex, s[i] == "\"" || s[i] == "'" {
                    let quote = s[i]
                    i = s.index(after: i)
                    let vs = i
                    while i < s.endIndex, s[i] != quote { i = s.index(after: i) }
                    value = String(s[vs..<i])
                    if i < s.endIndex { i = s.index(after: i) }
                } else {
                    let vs = i
                    while i < s.endIndex, !s[i].isWhitespace { i = s.index(after: i) }
                    value = String(s[vs..<i])
                }
            }
            result[name] = decodeEntities(value)
        }
        return result
    }
}

private final class Converter {
    let size: CGFloat
    let plain: Bool
    let rich = NSMutableAttributedString()
    var text = ""

    private var lastChar: Character?
    private var bold = 0, italic = 0, mono = 0, strike = 0, underline = 0
    private var quote = 0, mention = 0, heading = 0, pre = 0, skip = 0, emoji = 0
    private var links: [(href: String, start: Int)] = []
    private var lists: [(ordered: Bool, counter: Int)] = []
    private var needBreak = false
    private var prefix: String?
    private var cell = 0
    private var length = 0
    private var pendingImage: ImageRef?

    /// width="250", width="250px" or style="width:250px; height:100px"
    static func dimension(_ a: [String: String], _ name: String) -> CGFloat? {
        func number(_ s: Substring) -> CGFloat? {
            Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "px", with: "")).map { CGFloat($0) }
        }
        if let v = a[name], let n = number(Substring(v)), n > 0 { return n }
        for part in (a["style"] ?? "").split(separator: ";") {
            let kv = part.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == name, let n = number(kv[1]), n > 0 { return n }
        }
        return nil
    }

    init(size: CGFloat, plain: Bool) {
        self.size = size
        self.plain = plain
    }

    func run(_ html: String) {
        var i = html.startIndex
        let end = html.endIndex
        var segment = ""
        while i < end {
            let ch = html[i]
            guard ch == "<" else {
                segment.append(ch)
                i = html.index(after: i)
                continue
            }
            if html[i...].hasPrefix("<!--") {
                flush(&segment)
                i = html.range(of: "-->", range: i..<end)?.upperBound ?? end
                continue
            }
            let next = html.index(after: i)
            guard next < end, html[next] == "/" || html[next].isLetter else {
                segment.append(ch)
                i = next
                continue
            }
            var j = next
            var inQuote: Character?
            while j < end {
                let c = html[j]
                if let q = inQuote {
                    if c == q { inQuote = nil }
                } else if c == "\"" || c == "'" {
                    inQuote = c
                } else if c == ">" {
                    break
                }
                j = html.index(after: j)
            }
            guard j < end else {
                segment += html[i...]
                break
            }
            flush(&segment)
            tag(html[next..<j])
            i = html.index(after: j)
        }
        flush(&segment)
        trimEnd()
    }

    // MARK: Tags

    private func tag(_ raw: Substring) {
        var s = raw
        let closing = s.first == "/"
        if closing { s = s.dropFirst() }
        let selfClosing = s.last == "/"
        if selfClosing { s = s.dropLast() }
        let nameEnd = s.firstIndex(where: { $0.isWhitespace || $0 == "/" }) ?? s.endIndex
        let name = s[..<nameEnd].lowercased()

        if skip > 0 {
            if closing, ["script", "style", "head", "title"].contains(name) { skip -= 1 }
            return
        }
        if closing {
            close(name)
        } else {
            let attrs = ["a", "img", "emoji"].contains(name) ? HTML.attributes(s[nameEnd...]) : [:]
            open(name, attrs, selfClosing: selfClosing)
            if selfClosing, name != "br", name != "img", name != "hr" { close(name) }
        }
    }

    private func open(_ name: String, _ a: [String: String], selfClosing: Bool) {
        switch name {
        case "br": hardBreak()
        case "p", "div", "section", "article", "header", "footer", "table", "dl", "dt", "dd", "center", "figure":
            softBreak()
        case "tr":
            softBreak()
            cell = 0
        case "td", "th":
            if cell > 0 { emit("  │  ") }
            cell += 1
            if name == "th" { bold += 1 }
        case "h1", "h2", "h3", "h4", "h5", "h6":
            softBreak()
            heading += 1
        case "b", "strong": bold += 1
        case "i", "em", "cite": italic += 1
        case "u", "ins": underline += 1
        case "s", "strike", "del": strike += 1
        case "code", "kbd", "samp", "tt": mono += 1
        case "pre", "codeblock":
            softBreak()
            pre += 1
            mono += 1
        case "blockquote":
            softBreak()
            quote += 1
        case "a": links.append((a["href"] ?? "", length))
        case "at": mention += 1
        case "ul", "ol":
            softBreak()
            lists.append((name == "ol", 0))
        case "li":
            softBreak()
            if !lists.isEmpty { lists[lists.count - 1].counter += 1 }
            let marker = lists.last.map { $0.ordered ? "\($0.counter). " : "• " } ?? "• "
            prefix = String(repeating: "    ", count: max(lists.count - 1, 0)) + marker
        case "hr":
            softBreak()
            emit("──────────")
            softBreak()
        case "img":
            guard emoji == 0 else { return }
            let alt = a["alt"] ?? ""
            let isEmoji = (a["itemtype"] ?? "").lowercased().contains("emoji")
                || (!alt.isEmpty && alt.count <= 3 && alt.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0xFF })
            if isEmoji {
                emit(alt)
            } else if !plain, let src = a["src"], src.hasPrefix("https://") {
                // Own line, replaced by a thumbnail in Transcript.
                softBreak()
                pendingImage = ImageRef(src: src, width: Self.dimension(a, "width"), height: Self.dimension(a, "height"))
                emit("\u{FFFC}")
                pendingImage = nil
                softBreak()
            } else {
                emit("🖼 Image")
            }
        case "emoji":
            if let alt = a["alt"], !alt.isEmpty { emit(alt) }
            if !selfClosing { emoji += 1 }
        case "script", "style", "head", "title":
            if !selfClosing { skip += 1 }
        default:
            break
        }
    }

    private func close(_ name: String) {
        switch name {
        case "p", "div", "section", "article", "header", "footer", "table", "tr", "dl", "dt", "dd", "center", "figure", "li":
            softBreak()
        case "th": bold = max(bold - 1, 0)
        case "h1", "h2", "h3", "h4", "h5", "h6":
            heading = max(heading - 1, 0)
            softBreak()
        case "b", "strong": bold = max(bold - 1, 0)
        case "i", "em", "cite": italic = max(italic - 1, 0)
        case "u", "ins": underline = max(underline - 1, 0)
        case "s", "strike", "del": strike = max(strike - 1, 0)
        case "code", "kbd", "samp", "tt": mono = max(mono - 1, 0)
        case "pre", "codeblock":
            pre = max(pre - 1, 0)
            mono = max(mono - 1, 0)
            softBreak()
        case "blockquote":
            quote = max(quote - 1, 0)
            softBreak()
        case "a":
            guard let link = links.popLast() else { return }
            if link.start == length, let url = HTML.safeURL(link.href) {
                // Anchor without text: show the address itself.
                links.append(link)
                emit(url.absoluteString)
                links.removeLast()
            }
        case "at": mention = max(mention - 1, 0)
        case "ul", "ol":
            _ = lists.popLast()
            softBreak()
        case "emoji": emoji = max(emoji - 1, 0)
        default: break
        }
    }

    // MARK: Output

    private func flush(_ segment: inout String) {
        guard !segment.isEmpty else { return }
        defer { segment = "" }
        guard skip == 0, emoji == 0 else { return }
        var t = HTML.decodeEntities(segment)
        if pre == 0 {
            t = HTML.collapse(t)
            if needBreak || lastChar == nil || lastChar == "\n" || lastChar == " " {
                t = String(t.drop(while: { $0 == " " }))
            }
            if t.isEmpty { return }
        }
        emit(t)
    }

    private func softBreak() {
        if length > 0 { needBreak = true }
    }

    private func hardBreak() {
        if needBreak, lastChar != "\n" { append("\n") }
        needBreak = false
        append("\n")
    }

    private func emit(_ s: String) {
        if needBreak {
            if lastChar != "\n", length > 0 {
                trimTrailingSpace()
                append("\n")
            }
            needBreak = false
        }
        if let p = prefix {
            prefix = nil
            append(p)
        }
        append(s)
    }

    private func append(_ s: String) {
        guard !s.isEmpty else { return }
        if plain {
            text += s
        } else {
            var attrs = currentAttributes()
            if let pendingImage, s == "\u{FFFC}" { attrs[.teamsLiteImage] = pendingImage }
            rich.append(NSAttributedString(string: s, attributes: attrs))
        }
        length += (s as NSString).length
        lastChar = s.last
    }

    private func trimTrailingSpace() {
        guard lastChar == " " else { return }
        if plain {
            text.removeLast()
        } else {
            rich.deleteCharacters(in: NSRange(location: rich.length - 1, length: 1))
        }
        length -= 1
        lastChar = plain ? text.last : rich.string.last
    }

    private func trimEnd() {
        if plain {
            while let c = text.last, c.isWhitespace { text.removeLast() }
        } else {
            while rich.length > 0, let c = rich.string.last, c.isWhitespace {
                rich.deleteCharacters(in: NSRange(location: rich.length - (String(c) as NSString).length,
                                                  length: (String(c) as NSString).length))
            }
        }
    }

    private func currentAttributes() -> [NSAttributedString.Key: Any] {
        let fontSize = heading > 0 ? size + 2 : (mono > 0 ? size - 1 : size)
        let weight: NSFont.Weight = (bold > 0 || heading > 0 || mention > 0) ? .semibold : .regular
        var font = mono > 0 ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: weight)
                            : NSFont.systemFont(ofSize: fontSize, weight: weight)
        if italic > 0 || quote > 0 { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var a: [NSAttributedString.Key: Any] = [.font: font]
        if mention > 0 {
            a[.foregroundColor] = NSColor.controlAccentColor
        } else if quote > 0 {
            a[.foregroundColor] = NSColor.secondaryLabelColor
        } else {
            a[.foregroundColor] = NSColor.labelColor
        }
        if let href = links.last?.href, let url = HTML.safeURL(href) { a[.link] = url }
        if strike > 0 { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if underline > 0 { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if quote > 0 || !lists.isEmpty {
            let p = NSMutableParagraphStyle()
            let indent = CGFloat(quote) * 12 + (lists.isEmpty ? 0 : CGFloat(lists.count) * 14)
            p.firstLineHeadIndent = CGFloat(quote) * 12
            p.headIndent = indent
            p.paragraphSpacing = 2
            a[.paragraphStyle] = p
        }
        return a
    }
}
