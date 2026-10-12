import AppKit
import ServiceManagement

@main
struct TeamsLiteMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let model = AppModel()
    private var window: NSWindow?
    private let args = CommandLine.arguments
    private var askedPresenceConsent = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = args.firstIndex(of: "--appearance"), i + 1 < args.count {
            NSApp.appearance = NSAppearance(named: args[i + 1] == "dark" ? .darkAqua : .aqua)
        }
        NSApp.mainMenu = makeMenu()
        model.onSessionChange = { [weak self] in self?.updateContent() }
        model.onOpenChatRequest = { [weak self] id in
            self?.showWindow()
            (self?.window?.contentViewController as? MainViewController)?.select(chatId: id)
        }
        model.isWindowVisible = { [weak self] in
            guard let w = self?.window else { return false }
            return w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
        }
        model.onPresenceNeedsConsent = { [weak self] in self?.askPresenceConsent() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake(_:)),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        showWindow()
        model.start(demo: args.contains("--demo"))
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count { snapshot(to: args[i + 1]) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.appDidBecomeActive()
    }

    @objc private func didWake(_ note: Notification) {
        model.didWake()
    }

    // MARK: Window

    private func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: true)
            w.isReleasedWhenClosed = false
            w.title = "TeamsLite"
            w.minSize = NSSize(width: 640, height: 420)
            w.delegate = self
            w.tabbingMode = .disallowed
            if !w.setFrameUsingName("TeamsLiteMain") { w.center() }
            w.setFrameAutosaveName("TeamsLiteMain")
            window = w
            updateContent()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateContent() {
        guard let w = window else { return }
        let vc: NSViewController
        if model.signedIn {
            if w.contentViewController is MainViewController { return }
            vc = MainViewController(model: model)
        } else {
            if w.contentViewController is SignInViewController { return }
            vc = SignInViewController(model: model)
        }
        // Keep the current window size when swapping screens.
        vc.view.frame = NSRect(origin: .zero, size: w.contentRect(forFrameRect: w.frame).size)
        w.contentViewController = vc
    }

    func windowWillClose(_ notification: Notification) {
        // Release the whole UI (views, text, backing stores); the app keeps
        // running in the Dock and still delivers notifications.
        DispatchQueue.main.async {
            self.window?.contentViewController = nil
            self.window = nil
        }
    }

    // MARK: Menu

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About TeamsLite", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        app.addItem(withTitle: "Always Show Me as Available", action: #selector(toggleAvailable(_:)), keyEquivalent: "")
        app.addItem(withTitle: "Grant Status Permission…", action: #selector(grantPresence(_:)), keyEquivalent: "")
        app.addItem(withTitle: "Sign Out…", action: #selector(signOut(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide TeamsLite", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit TeamsLite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, title: "TeamsLite"))

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Chat…", action: #selector(newChat(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "Refresh", action: #selector(refresh(_:)), keyEquivalent: "r")
        file.addItem(withTitle: "Open Chat in Teams", action: #selector(openInTeams(_:)), keyEquivalent: "o")
            .keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(file, title: "File"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Emoji & Symbols", action: #selector(NSApplication.orderFrontCharacterPalette(_:)), keyEquivalent: " ")
            .keyEquivalentModifierMask = [.command, .control]
        main.addItem(submenu(edit, title: "Edit"))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Chats", action: #selector(showMainWindow(_:)), keyEquivalent: "0")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(submenu(windowMenu, title: "Window"))
        NSApp.windowsMenu = windowMenu
        return main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(newChat(_:)), #selector(refresh(_:)), #selector(signOut(_:)):
            return model.signedIn
        case #selector(toggleAvailable(_:)):
            item.state = Config.alwaysAvailable ? .on : .off
            return model.signedIn
        case #selector(grantPresence(_:)):
            item.isHidden = model.presence != .needsConsent
            return model.signedIn
        case #selector(openInTeams(_:)):
            return model.currentChatId.flatMap { model.chat($0)?.webUrl } != nil
        default:
            return true
        }
    }

    @objc private func showMainWindow(_ sender: Any?) { showWindow() }

    @objc private func toggleAvailable(_ sender: Any?) {
        UserDefaults.standard.set(!Config.alwaysAvailable, forKey: "alwaysAvailable")
        model.presenceSettingChanged()
    }

    @objc private func grantPresence(_ sender: Any?) {
        Task {
            do {
                try await model.grantPresence()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// Asked once per launch when Presence.ReadWrite hasn't been granted to the client yet.
    private func askPresenceConsent() {
        guard !askedPresenceConsent, Config.alwaysAvailable else { return }
        askedPresenceConsent = true
        let alert = NSAlert()
        alert.messageText = "Allow TeamsLite to keep you Available?"
        alert.informativeText = "Showing you as Available needs one more Microsoft permission (Presence.ReadWrite). Your browser opens once to approve it; your chats stay as they are."
        alert.addButton(withTitle: "Open Browser")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        grantPresence(nil)
    }

    @objc private func newChat(_ sender: Any?) {
        showWindow()
        (window?.contentViewController as? MainViewController)?.newChat(nil)
    }

    @objc private func refresh(_ sender: Any?) {
        Task { await model.refreshAll() }
    }

    @objc private func openInTeams(_ sender: Any?) {
        model.openInTeams()
    }

    @objc private func signOut(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Sign out of TeamsLite?"
        alert.informativeText = model.username.isEmpty ? "" : "Signed in as \(model.username)."
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await model.signOut() }
    }

    @objc private func showSettings(_ sender: Any?) {
        let defaults = UserDefaults.standard
        func field(_ key: String, placeholder: String) -> NSTextField {
            let f = NSTextField(string: defaults.string(forKey: key) ?? "")
            f.placeholderString = placeholder
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 330).isActive = true
            return f
        }
        let relay = field("relayURL", placeholder: Config.relayPlaceholder)
        let client = field("clientID", placeholder: Config.defaultClientID)
        let tenant = field("tenant", placeholder: Config.defaultTenant)
        let available = NSButton(checkboxWithTitle: "Always show me as Available", target: nil, action: nil)
        available.state = Config.alwaysAvailable ? .on : .off
        let login = NSButton(checkboxWithTitle: "Open TeamsLite at login", target: nil, action: nil)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Relay URL:"), relay],
            [NSTextField(labelWithString: "Client ID:"), client],
            [NSTextField(labelWithString: "Tenant:"), tenant],
            [NSGridCell.emptyContentView, available],
            [NSGridCell.emptyContentView, login],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)

        let alert = NSAlert()
        alert.messageText = "TeamsLite Settings"
        alert.informativeText = "Leave a field empty to use the default. Type “off” as the relay URL to turn live updates off. Changing the client ID or tenant takes effect after you sign in again."
        alert.accessoryView = grid
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let oldRelay = Config.relayURL
        for (key, f) in [("relayURL", relay), ("clientID", client), ("tenant", tenant)] {
            let v = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(v, forKey: key) }
        }
        if Config.relayURL != oldRelay { model.relaySettingsChanged() }
        if (available.state == .on) != Config.alwaysAvailable {
            defaults.set(available.state == .on, forKey: "alwaysAvailable")
            model.presenceSettingChanged()
        }

        let wantLogin = login.state == .on
        if wantLogin != (SMAppService.mainApp.status == .enabled) {
            do {
                if wantLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    // MARK: Testing aid

    /// `--snapshot <file.png>` renders the window into a PNG and quits (no screen-recording permission needed).
    private func snapshot(to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if let view = self.window?.contentView?.superview ?? self.window?.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }
}
