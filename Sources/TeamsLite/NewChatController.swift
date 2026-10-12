import AppKit

/// Sheet for starting a 1:1 chat: type a name or email, pick a person.
final class NewChatController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let model: AppModel
    var onChat: ((String) -> Void)?

    private let field = NSSearchField()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "Open Chat", target: nil, action: nil)
    private var results: [UserDTO] = []
    private var searchTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 360))
        let title = NSTextField(labelWithString: "New chat")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        field.placeholderString = "Name or email"
        field.delegate = self
        field.sendsSearchStringImmediately = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("person"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 36
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(open(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingTail

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(close(_:)))
        cancel.keyEquivalent = "\u{1b}"
        openButton.target = self
        openButton.action = #selector(open(_:))
        openButton.keyEquivalent = "\r"
        openButton.isEnabled = false

        for v in [title, field, scroll, status, cancel, openButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 420),
            root.heightAnchor.constraint(equalToConstant: 360),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            field.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: openButton.topAnchor, constant: -14),
            openButton.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            openButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            cancel.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: openButton.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            status.centerYAnchor.constraint(equalTo: openButton.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: cancel.leadingAnchor, constant: -8),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) {
        searchTask?.cancel()
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else {
            results = []
            table.reloadData()
            openButton.isEnabled = false
            status.stringValue = ""
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            status.stringValue = "Searching…"
            do {
                let found = try await model.searchUsers(query)
                guard !Task.isCancelled else { return }
                results = found
                table.reloadData()
                if !found.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
                openButton.isEnabled = !found.isEmpty
                status.stringValue = found.isEmpty ? "No one found" : ""
            } catch {
                if !Task.isCancelled { status.stringValue = error.localizedDescription }
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)):
            open(nil)
        case #selector(NSResponder.cancelOperation(_:)):
            close(nil)
        default:
            return false
        }
        return true
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let row = min(max(table.selectedRow + delta, 0), results.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("PersonCell")
        let label: NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField {
            label = reused
        } else {
            label = NSTextField(labelWithString: "")
            label.identifier = id
            label.lineBreakMode = .byTruncatingTail
        }
        let user = results[row]
        let text = NSMutableAttributedString(string: user.displayName ?? "Unknown",
                                             attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        if let mail = user.mail ?? user.userPrincipalName {
            text.append(NSAttributedString(string: "   " + mail, attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                             .foregroundColor: NSColor.secondaryLabelColor]))
        }
        label.attributedStringValue = text
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        openButton.isEnabled = table.selectedRow >= 0
    }

    // MARK: Actions

    @objc private func open(_ sender: Any?) {
        let row = table.selectedRow >= 0 ? table.selectedRow : (results.isEmpty ? -1 : 0)
        guard row >= 0, row < results.count else { return }
        let user = results[row]
        openButton.isEnabled = false
        status.stringValue = "Opening chat…"
        Task {
            do {
                let id = try await model.chatWith(user)
                dismiss(nil)
                onChat?(id)
            } catch {
                status.stringValue = error.localizedDescription
                openButton.isEnabled = true
            }
        }
    }

    @objc private func close(_ sender: Any?) {
        searchTask?.cancel()
        dismiss(nil)
    }
}
