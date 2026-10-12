import AppKit
import UniformTypeIdentifiers

/// Chat list on the left, conversation + composer on the right. Plain AppKit views,
/// no vibrancy/visual-effect layers, one NSTextView for the whole transcript.
final class MainViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                                NSTextViewDelegate, NSMenuDelegate, NSSplitViewDelegate {
    private let model: AppModel

    private let table = NSTableView()
    private let statusDot = NSTextField(labelWithString: "●")
    private let statusLabel = NSTextField(labelWithString: "")

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton()
    private let detail = NSView()
    private let emptyLabel = NSTextField(labelWithString: "Select a chat to start messaging")

    // Text systems are built by hand (TextKit 1); the storages must be retained here.
    private let transcriptStorage = NSTextStorage()
    private var transcript: NSTextView!
    private let transcriptScroll = NSScrollView()
    private let composerStorage = NSTextStorage()
    private var composer: ComposerTextView!
    private let composerScroll = NSScrollView()
    private let sendButton = NSButton()
    private let attachButton = NSButton()
    private let imagesLabel = NSTextField(labelWithString: "")
    private let imagesRemove = NSButton(title: "Remove", target: nil, action: nil)
    private var imagesRowHeight: NSLayoutConstraint!
    private var composerHeight: NSLayoutConstraint!

    private var suppressSelection = false
    private var renderedChatId: String?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        let sidebar = makeSidebar()
        makeDetail()
        // Initial frames give the split view its starting divider position.
        sidebar.frame = NSRect(x: 0, y: 0, width: 280, height: 620)
        detail.frame = NSRect(x: 281, y: 0, width: 619, height: 620)
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(detail)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 1)
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        split.autosaveName = "TeamsLiteSplit"
        view = split
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.onChatsChange = { [weak self] in self?.reloadChats() }
        model.onConversationChange = { [weak self] id, older in
            guard let self, id == self.model.currentChatId else { return }
            self.renderConversation(keepPosition: older)
        }
        model.onStatusChange = { [weak self] in self?.updateStatus() }
        model.onSendFailed = { [weak self] id, text, images in
            guard let self, id == self.model.currentChatId, self.composer.string.isEmpty else { return }
            self.composer.string = text
            self.model.draftImages[id] = images.isEmpty ? nil : images
            self.composerChanged()
            self.updateImagesRow()
        }
        reloadChats()
        renderConversation()
        updateStatus()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let split = view as? NSSplitView, let side = split.arrangedSubviews.first, side.frame.width < 200 {
            split.setPosition(280, ofDividerAt: 0)
        }
        view.window?.makeFirstResponder(model.currentChatId == nil ? table : composer)
    }

    // MARK: Building

    private func makeSidebar() -> NSView {
        let v = NSView()
        let header = NSTextField(labelWithString: "Chats")
        header.font = .systemFont(ofSize: 15, weight: .semibold)

        let newButton = NSButton(image: NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "New chat")!,
                                 target: self, action: #selector(newChat(_:)))
        newButton.isBordered = false
        newButton.toolTip = "New chat (⌘N)"

        statusDot.font = .systemFont(ofSize: 9)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("chat"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 50
        table.style = .inset
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        table.backgroundColor = .clear

        for sub in [header, newButton, statusDot, statusLabel, scroll] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(sub)
        }
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            header.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            newButton.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -14),
            newButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusDot.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            statusDot.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 3),
            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 3),
            statusLabel.centerYAnchor.constraint(equalTo: statusDot.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: statusDot.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        return v
    }

    private func makeDetail() {
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        openButton.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: "Open in Teams")
        openButton.isBordered = false
        openButton.target = self
        openButton.action = #selector(openInTeams(_:))
        openButton.toolTip = "Open this chat in Teams (files, calls, …)"

        let topLine = NSBox()
        topLine.boxType = .separator
        let bottomLine = NSBox()
        bottomLine.boxType = .separator

        // Transcript
        transcript = NSTextView(frame: .zero, textContainer: Self.textContainer(for: transcriptStorage))
        configure(transcript)
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.textContainerInset = NSSize(width: 14, height: 12)
        transcript.delegate = self
        transcript.linkTextAttributes = [.foregroundColor: NSColor.linkColor,
                                         .cursor: NSCursor.pointingHand]
        transcriptScroll.documentView = transcript
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true

        // Composer
        composer = ComposerTextView(frame: .zero, textContainer: Self.textContainer(for: composerStorage))
        configure(composer)
        composer.isRichText = false
        composer.importsGraphics = false
        composer.allowsUndo = true
        composer.isAutomaticQuoteSubstitutionEnabled = false
        composer.isAutomaticDashSubstitutionEnabled = false
        composer.font = .systemFont(ofSize: 13)
        composer.textContainerInset = NSSize(width: 8, height: 8)
        composer.delegate = self
        composer.onSend = { [weak self] in self?.sendCurrent() }
        composer.onImages = { [weak self] data in self?.addImages(data) }
        composerScroll.documentView = composer
        composerScroll.hasVerticalScroller = true
        composerScroll.autohidesScrollers = true
        composerScroll.drawsBackground = true
        composerScroll.backgroundColor = .textBackgroundColor

        sendButton.image = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: "Send")
        sendButton.isBordered = false
        sendButton.contentTintColor = .controlAccentColor
        sendButton.target = self
        sendButton.action = #selector(sendClicked(_:))
        sendButton.toolTip = "Send (Return). Shift-Return for a new line."

        attachButton.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "Attach image")
        attachButton.isBordered = false
        attachButton.contentTintColor = .secondaryLabelColor
        attachButton.target = self
        attachButton.action = #selector(attachClicked(_:))
        attachButton.toolTip = "Attach images (you can also paste or drop them)"

        imagesLabel.font = .systemFont(ofSize: 11)
        imagesLabel.textColor = .secondaryLabelColor
        imagesRemove.bezelStyle = .inline
        imagesRemove.controlSize = .small
        imagesRemove.target = self
        imagesRemove.action = #selector(removeImages(_:))

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)

        for sub in [titleLabel, subtitleLabel, openButton, topLine, transcriptScroll, bottomLine,
                    composerScroll, sendButton, attachButton, imagesLabel, imagesRemove, emptyLabel] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            detail.addSubview(sub)
        }
        composerHeight = composerScroll.heightAnchor.constraint(equalToConstant: 34)
        imagesRowHeight = imagesLabel.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: detail.topAnchor, constant: 9),
            titleLabel.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -8),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -8),
            openButton.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -14),
            openButton.centerYAnchor.constraint(equalTo: titleLabel.bottomAnchor),

            topLine.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
            topLine.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: detail.trailingAnchor),

            transcriptScroll.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            transcriptScroll.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            transcriptScroll.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            transcriptScroll.bottomAnchor.constraint(equalTo: bottomLine.topAnchor),

            bottomLine.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: imagesLabel.topAnchor, constant: -4),
            imagesLabel.leadingAnchor.constraint(equalTo: composerScroll.leadingAnchor, constant: 6),
            imagesLabel.bottomAnchor.constraint(equalTo: composerScroll.topAnchor, constant: -2),
            imagesRowHeight,
            imagesRemove.leadingAnchor.constraint(equalTo: imagesLabel.trailingAnchor, constant: 6),
            imagesRemove.centerYAnchor.constraint(equalTo: imagesLabel.centerYAnchor),

            attachButton.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 12),
            attachButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            attachButton.widthAnchor.constraint(equalToConstant: 22),
            composerScroll.leadingAnchor.constraint(equalTo: attachButton.trailingAnchor, constant: 6),
            composerScroll.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            composerScroll.bottomAnchor.constraint(equalTo: detail.bottomAnchor, constant: -8),
            composerHeight,

            sendButton.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -14),
            sendButton.bottomAnchor.constraint(equalTo: composerScroll.bottomAnchor, constant: -7),
            sendButton.widthAnchor.constraint(equalToConstant: 22),

            emptyLabel.centerXAnchor.constraint(equalTo: detail.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: detail.centerYAnchor),
        ])
    }

    private static func textContainer(for storage: NSTextStorage) -> NSTextContainer {
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        return container
    }

    private func configure(_ tv: NSTextView) {
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
    }

    // MARK: Chat list

    func numberOfRows(in tableView: NSTableView) -> Int { model.chats.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ChatCell.id, owner: nil) as? ChatCell ?? ChatCell()
        let chat = model.chats[row]
        cell.configure(title: model.title(of: chat), preview: previewLine(chat),
                       time: Fmt.listTime(chat.lastMessageAt), unread: chat.isUnread(me: model.me))
        return cell
    }

    private func previewLine(_ chat: Chat) -> String {
        guard !chat.lastPreview.isEmpty else { return chat.subtitle() }
        if chat.lastSenderId == model.me { return "You: " + chat.lastPreview }
        if chat.chatType != "oneOnOne", chat.lastIsUserMessage, let name = chat.lastSenderName {
            return (name.split(separator: " ").first.map(String.init) ?? name) + ": " + chat.lastPreview
        }
        return chat.lastPreview
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        let row = table.selectedRow
        let id = row >= 0 && row < model.chats.count ? model.chats[row].id : nil
        guard id != model.currentChatId else { return }
        saveDraft()
        model.openChat(id)
        restoreDraft()
        renderConversation()
    }

    func reloadChats() {
        suppressSelection = true
        table.reloadData()
        if let id = model.currentChatId, let row = model.chats.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        suppressSelection = false
        updateHeader()
    }

    /// Selects a chat programmatically (notification click, new chat).
    func select(chatId: String) {
        if chatId != model.currentChatId {
            saveDraft()
            model.openChat(chatId)
            restoreDraft()
        }
        reloadChats()
        if let row = model.chats.firstIndex(where: { $0.id == chatId }) { table.scrollRowToVisible(row) }
        renderConversation()
        view.window?.makeFirstResponder(composer)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard row >= 0, row < model.chats.count else { return }
        let chat = model.chats[row]
        if chat.isUnread(me: model.me) {
            let item = menu.addItem(withTitle: "Mark as Read", action: #selector(markRead(_:)), keyEquivalent: "")
            item.representedObject = chat.id
            item.target = self
        }
        let open = menu.addItem(withTitle: "Open in Teams", action: #selector(openInTeams(_:)), keyEquivalent: "")
        open.representedObject = chat.id
        open.target = self
    }

    @objc private func markRead(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { model.markRead(id) }
    }

    @objc func openInTeams(_ sender: Any?) {
        model.openInTeams((sender as? NSMenuItem)?.representedObject as? String)
    }

    @objc func newChat(_ sender: Any?) {
        guard presentedViewControllers?.isEmpty ?? true else { return }
        let picker = NewChatController(model: model)
        picker.onChat = { [weak self] id in self?.select(chatId: id) }
        presentAsSheet(picker)
    }

    // MARK: Conversation

    func renderConversation(keepPosition: Bool = false) {
        guard let id = model.currentChatId, model.chat(id) != nil else {
            renderedChatId = nil
            transcriptStorage.setAttributedString(NSAttributedString())
            setDetailVisible(false)
            updateHeader()
            return
        }
        setDetailVisible(true)
        let clip = transcriptScroll.contentView
        let oldHeight = transcript.frame.height
        let switched = renderedChatId != id
        let atBottom = clip.bounds.maxY >= oldHeight - 40
        let fromBottom = oldHeight - clip.bounds.minY

        transcriptStorage.setAttributedString(Transcript.render(model.conversation(id), me: model.me, images: model.images))
        if let container = transcript.textContainer { transcript.layoutManager?.ensureLayout(for: container) }
        transcript.sizeToFit()

        if keepPosition, !switched {
            clip.scroll(to: NSPoint(x: 0, y: max(0, transcript.frame.height - fromBottom)))
            transcriptScroll.reflectScrolledClipView(clip)
        } else if switched || atBottom {
            transcript.scrollToEndOfDocument(nil)
        }
        renderedChatId = id
        updateHeader()
        if let row = model.chats.firstIndex(where: { $0.id == id }), table.selectedRow != row {
            suppressSelection = true
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            suppressSelection = false
        }
    }

    private func setDetailVisible(_ visible: Bool) {
        for v in [titleLabel, subtitleLabel, openButton, transcriptScroll, composerScroll, sendButton, attachButton] as [NSView] {
            v.isHidden = !visible
        }
        updateImagesRow()
        emptyLabel.isHidden = visible
    }

    private func updateHeader() {
        guard let id = model.currentChatId, let chat = model.chat(id) else {
            view.window?.title = "TeamsLite"
            return
        }
        let title = model.title(of: chat)
        titleLabel.stringValue = title
        subtitleLabel.stringValue = chat.subtitle()
        openButton.isEnabled = chat.webUrl != nil
        view.window?.title = title
    }

    private func updateStatus() {
        let s = model.liveStatus
        statusDot.textColor = s.color
        statusLabel.stringValue = s.text
        statusLabel.toolTip = s.detail
        statusDot.toolTip = s.detail
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url else { return false }
        if url == Transcript.olderLink {
            if let id = model.currentChatId { model.loadOlder(id) }
        } else if let src = Transcript.imageSource(url) {
            model.openImage(src)
        } else {
            NSWorkspace.shared.open(url)
        }
        return true
    }

    /// Clicks on an image attachment (some macOS versions report these instead of a link click).
    func textView(_ view: NSTextView, clickedOn cell: NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
        guard charIndex < transcriptStorage.length,
              let url = transcriptStorage.attribute(.link, at: charIndex, effectiveRange: nil) as? URL,
              let src = Transcript.imageSource(url) else { return }
        model.openImage(src)
    }

    // MARK: Composer

    func textDidChange(_ notification: Notification) {
        if (notification.object as? NSTextView) === composer { composerChanged() }
    }

    private func composerChanged() {
        guard let layout = composer.layoutManager, let container = composer.textContainer else { return }
        layout.ensureLayout(for: container)
        let height = layout.usedRect(for: container).height + composer.textContainerInset.height * 2
        composerHeight.constant = min(max(ceil(height), 34), 150)
        composer.needsDisplay = true
    }

    @objc private func sendClicked(_ sender: Any?) { sendCurrent() }

    private func sendCurrent() {
        guard let id = model.currentChatId else { return }
        let text = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = model.draftImages[id] ?? []
        guard !text.isEmpty || !images.isEmpty else { return }
        composer.string = ""
        composerChanged()
        model.drafts[id] = nil
        model.draftImages[id] = nil
        updateImagesRow()
        model.send(text, images: images, to: id)
    }

    // MARK: Outgoing images

    @objc private func attachClicked(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.addImages(panel.urls.compactMap { try? Data(contentsOf: $0) })
        }
    }

    @objc private func removeImages(_ sender: Any?) {
        if let id = model.currentChatId { model.draftImages[id] = nil }
        updateImagesRow()
    }

    private func addImages(_ data: [Data]) {
        guard let id = model.currentChatId, !data.isEmpty else { return }
        Task {
            // Decoding / re-encoding happens off the main thread.
            let prepared = await Task.detached { data.compactMap { OutgoingImage.make(from: $0) } }.value
            var list = model.draftImages[id] ?? []
            var total = list.reduce(0) { $0 + $1.data.count }
            var skipped = data.count - prepared.count
            for img in prepared {
                // Graph caps a request at ~4 MB, and base64 adds a third.
                if total + img.data.count > OutgoingImage.maxTotalBytes || list.count >= 6 { skipped += 1; continue }
                list.append(img)
                total += img.data.count
            }
            model.draftImages[id] = list.isEmpty ? nil : list
            updateImagesRow(note: skipped > 0 ? "\(skipped) skipped (too large or unsupported)" : nil)
            view.window?.makeFirstResponder(composer)
        }
    }

    private func updateImagesRow(note: String? = nil) {
        let count = model.currentChatId.flatMap { model.draftImages[$0]?.count } ?? 0
        var text = count == 0 ? "" : "🖼 \(count) image\(count == 1 ? "" : "s") attached"
        if let note { text += text.isEmpty ? note : " · " + note }
        imagesLabel.stringValue = text
        imagesLabel.isHidden = text.isEmpty
        imagesRemove.isHidden = count == 0
        imagesRowHeight.constant = text.isEmpty ? 0 : 16
    }

    private func saveDraft() {
        guard let id = model.currentChatId else { return }
        let text = composer.string
        model.drafts[id] = text.isEmpty ? nil : text
    }

    private func restoreDraft() {
        composer.string = model.currentChatId.flatMap { model.drafts[$0] } ?? ""
        composerChanged()
        updateImagesRow()
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
}

/// Composer: Return sends, Shift/Option-Return inserts a newline.
final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var onImages: (([Data]) -> Void)?
    var placeholder = "Type a message"

    /// Pasted screenshots / copied images become attachments; text still pastes as text.
    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isFile = pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let textIsJustURL = !text.contains(" ") && (text.hasPrefix("http") || text.hasPrefix("file:"))
        if text.isEmpty || isFile || textIsJustURL {
            let images = OutgoingImage.from(pasteboard: pb)
            if !images.isEmpty {
                onImages?(images)
                return
            }
        }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        OutgoingImage.hasImages(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL, .png, .tiff]
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        OutgoingImage.hasImages(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let images = OutgoingImage.from(pasteboard: sender.draggingPasteboard)
        guard !images.isEmpty else { return super.performDragOperation(sender) }
        onImages?(images)
        return true
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !hasMarkedText() {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.contains(.shift) || mods.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSend?()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let font else { return }
        let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5)
        (placeholder as NSString).draw(at: NSPoint(x: x, y: textContainerInset.height),
                                       withAttributes: [.font: font, .foregroundColor: NSColor.placeholderTextColor])
    }
}

final class ChatCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("ChatCell")

    private let name = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let preview = NSTextField(labelWithString: "")
    private let dot = NSTextField(labelWithString: "●")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        textField = name
        name.lineBreakMode = .byTruncatingTail
        time.font = .systemFont(ofSize: 11)
        time.textColor = .secondaryLabelColor
        time.alignment = .right
        preview.font = .systemFont(ofSize: 12)
        preview.textColor = .secondaryLabelColor
        preview.lineBreakMode = .byTruncatingTail
        dot.font = .systemFont(ofSize: 8)
        dot.textColor = .controlAccentColor
        for v in [name, time, preview, dot] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        time.setContentHuggingPriority(.required, for: .horizontal)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            dot.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            name.trailingAnchor.constraint(lessThanOrEqualTo: time.leadingAnchor, constant: -6),
            time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            time.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            preview.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            preview.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(title: String, preview text: String, time stamp: String, unread: Bool) {
        name.stringValue = title
        name.font = .systemFont(ofSize: 13, weight: unread ? .bold : .regular)
        preview.stringValue = text
        preview.textColor = unread ? .labelColor : .secondaryLabelColor
        time.stringValue = stamp
        dot.isHidden = !unread
    }
}
