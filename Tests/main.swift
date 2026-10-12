import AppKit

var failures = 0
func check(_ name: String, _ got: String, _ want: String) {
    if got == want { print("ok   \(name)") } else { failures += 1; print("FAIL \(name)\n     got:  \(got.debugDescription)\n     want: \(want.debugDescription)") }
}

@MainActor func run() {
    let nb = "\u{00A0}"
    check("plain paragraphs", HTML.plainText("<p>Hello&nbsp;<b>world</b></p><p>Second</p>"), "Hello\(nb)world Second")
    check("teams copy-paste block", HTML.plainText("<div>\n<div itemprop=\"copy-paste-block\">reply 9&nbsp;to new conv</div>\n</div>"), "reply 9\(nb)to new conv")
    check("emoji tag", HTML.plainText("<p>Hi <emoji id=\"smile\" alt=\"😄\" title=\"Smile\"></emoji></p>"), "Hi 😄")
    check("emoji img", HTML.plainText("<p>Ok <img alt=\"👍\" itemtype=\"http://schema.skype.com/Emoji\" src=\"x\"></p>"), "Ok 👍")
    check("image", HTML.plainText("<p><img src=\"https://graph/hosted\" alt=\"image\"></p>"), "🖼 Image")
    check("mention", HTML.plainText("<p><at id=\"0\">Dušan Đorđević</at> check this</p>"), "Dušan Đorđević check this")
    check("entities", HTML.plainText("&lt;tag&gt; &amp; &#128512; &#x1F600; &quot;q&quot; &unknown;"), "<tag> & 😀 😀 \"q\" &unknown;")
    check("loose lt", HTML.plainText("a < b and c > d"), "a < b and c > d")
    check("attachment only", Preview.bodyText(BodyDTO(contentType: "html", content: "<attachment id=\"x\"></attachment>")), "📎 Attachment")
    check("script skipped", HTML.plainText("<p>a</p><script>alert(1)</script><p>b</p>"), "a b")

    let rich = HTML.attributed("<p>Line one</p><p>Line <b>two</b> <a href=\"https://example.com/x\">link</a></p><ul><li>A</li><li>B</li></ul><blockquote>quoted</blockquote><pre>let x = 1\n  y</pre>")
    check("rich text", rich.string, "Line one\nLine two link\n• A\n• B\nquoted\nlet x = 1\n  y")
    let linkRange = (rich.string as NSString).range(of: "link")
    check("rich link attr", (rich.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL)?.absoluteString ?? "nil", "https://example.com/x")
    check("br handling", HTML.attributed("a<br>b<br><br>c").string, "a\nb\n\nc")
    check("div br div", HTML.attributed("<div>line1</div><div><br></div><div>line2</div>").string, "line1\n\nline2")
    check("js link dropped", (HTML.attributed("<a href=\"javascript:alert(1)\">x</a>").attribute(.link, at: 0, effectiveRange: nil) == nil) ? "nil" : "link", "nil")
    let img = HTML.attributed("<p>Look:</p><p><img src=\"https://graph.microsoft.com/v1.0/chats/x/messages/1/hostedContents/a/$value\" style=\"width:250px; height:100px\"></p><p>done</p>")
    check("image placeholder", img.string, "Look:\n\u{FFFC}\ndone")
    let ref = img.attribute(.teamsLiteImage, at: 6, effectiveRange: nil) as? ImageRef
    check("image ref", ref.map { "\($0.src.hasSuffix("$value")) \($0.width ?? 0)x\($0.height ?? 0)" } ?? "nil", "true 250.0x100.0")
    check("newline not tagged", img.attribute(.teamsLiteImage, at: 5, effectiveRange: nil) == nil ? "clean" : "tagged", "clean")
    check("image size capped", "\(ImageRef(src: "", width: 1280, height: 640).displaySize())", "(320.0, 160.0)")
    let bare = HTML.attributed("see https://example.com/page ok")
    check("bare url linkified", (bare.attribute(.link, at: 6, effectiveRange: nil) as? URL)?.host ?? "nil", "example.com")

    check("outgoing html", HTML.fromPlainText("Hi <you> & https://example.com\nline2"),
          "Hi &lt;you&gt; &amp; <a href=\"https://example.com\">https://example.com</a><br>line2")

    func iso(_ s: String) -> String { GraphDate.parse(s).map { GraphDate.string($0) } ?? "nil" }
    check("date ms", iso("2021-06-05T00:31:30.047Z"), "2021-06-05T00:31:30.047Z")
    check("date 7 digits", iso("2024-09-26T15:58:19.9930000Z"), "2024-09-26T15:58:19.993Z")
    check("date offset", iso("2023-01-01T10:00:00+02:00"), "2023-01-01T08:00:00.000Z")
    check("date no fraction", iso("2020-12-04T23:10:28Z"), "2020-12-04T23:10:28.000Z")
    check("date year 1", GraphDate.parse("0001-01-01T00:00:00Z").map { $0 < Date(timeIntervalSince1970: 0) ? "past" : "?" } ?? "nil", "past")

    check("duration", Preview.duration("PT1H2M10S") ?? "nil", "1h 2m 10s")
    check("duration frac", Preview.duration("PT14M5.123S") ?? "nil", "14m 5s")

    let card = #"{"type":"AdaptiveCard","body":[{"type":"TextBlock","text":"Build 2481 succeeded"},{"type":"FactSet","facts":[{"title":"Pipeline:","value":"Webshop CI"}]}]}"#
    check("card text", Preview.cardText(card), "Build 2481 succeeded\nPipeline: Webshop CI")
    let o365 = #"{"sections":[{"activityTitle":"PR #12 merged","activityText":"<b>main</b> updated"}]}"#
    check("o365 card", Preview.cardText(o365), "PR #12 merged\nmain updated")

    let r1 = AppModel.parse("chats('19:8ea0e38b-efb3_97f62344@unq.gbl.spaces')/messages('1612289765949')")
    check("resource quoted", r1.map { "\($0.0)|\($0.1)" } ?? "nil", "19:8ea0e38b-efb3_97f62344@unq.gbl.spaces|1612289765949")
    let r2 = AppModel.parse("chats('19%3Aabc%40thread.v2')/messages('42')")
    check("resource encoded", r2.map { "\($0.0)|\($0.1)" } ?? "nil", "19:abc@thread.v2|42")
    let r3 = AppModel.parse("users/u1/chats/19:abc@thread.v2/messages/77")
    check("resource slashes", r3.map { "\($0.0)|\($0.1)" } ?? "nil", "19:abc@thread.v2|77")

    // Chat title and unread logic.
    let c = Chat(id: "c1")
    c.setMembers([MemberDTO(displayName: "Me", userId: "me", email: nil), MemberDTO(displayName: "Ana Petrović", userId: "a", email: "a@x")], me: "me")
    check("1:1 title", c.title(me: "me", myName: "Me"), "Ana Petrović")
    c.applyPreview(PreviewDTO(id: "1", createdDateTime: "2026-10-12T10:00:00Z", isDeleted: false, messageType: "message",
                              body: BodyDTO(contentType: "text", content: "hi"), from: FromDTO(user: IdentityDTO(id: "a", displayName: "Ana Petrović"), application: nil), eventDetail: nil), me: "me")
    c.lastReadAt = GraphDate.parse("2026-10-12T09:00:00Z")
    check("unread", c.isUnread(me: "me") ? "unread" : "read", "unread")
    c.lastReadAt = GraphDate.parse("2026-10-12T10:00:01Z")
    check("read", c.isUnread(me: "me") ? "unread" : "read", "read")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
}
await run()
exit(failures == 0 ? 0 : 1)
