import AppKit

final class SignInViewController: NSViewController {
    private let model: AppModel
    private let status = NSTextField(wrappingLabelWithString: "")
    private let signInButton = NSButton(title: "Sign in with Microsoft", target: nil, action: nil)
    private let codeButton = NSButton(title: "Use a sign-in code instead", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var task: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 80).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 80).isActive = true

        let title = NSTextField(labelWithString: "TeamsLite")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Microsoft Teams chats, without the weight.")
        subtitle.textColor = .secondaryLabelColor

        signInButton.bezelStyle = .rounded
        signInButton.controlSize = .large
        signInButton.keyEquivalent = "\r"
        signInButton.target = self
        signInButton.action = #selector(signIn(_:))

        codeButton.isBordered = false
        codeButton.contentTintColor = .linkColor
        codeButton.target = self
        codeButton.action = #selector(signInWithCode(_:))

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.isHidden = true

        status.alignment = .center
        status.textColor = .secondaryLabelColor
        status.isSelectable = true
        status.preferredMaxLayoutWidth = 380
        status.stringValue = model.signInNotice ?? "Your work account signs in through your default browser."

        let stack = NSStackView(views: [icon, title, subtitle, signInButton, codeButton, status, cancelButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(18, after: subtitle)
        stack.setCustomSpacing(16, after: codeButton)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -20),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            status.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
        view = root
    }

    @objc private func signIn(_ sender: Any?) {
        status.stringValue = "Waiting for you to finish signing in in the browser…"
        run { try await self.model.signInWithBrowser() }
    }

    @objc private func signInWithCode(_ sender: Any?) {
        status.stringValue = "Requesting a code…"
        run {
            let code = try await self.model.startDeviceCode()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code.user_code, forType: .string)
            self.status.stringValue = "Enter code \(code.user_code) at \(code.verification_uri)\n(copied to the clipboard; the page opens in your browser)"
            if let url = URL(string: code.verification_uri) { NSWorkspace.shared.open(url) }
            try await self.model.completeDeviceCode(code)
        }
    }

    @objc private func cancel(_ sender: Any?) {
        task?.cancel()
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        task?.cancel()
        setBusy(true)
        task = Task {
            do {
                try await operation()
            } catch is CancellationError {
                status.stringValue = "Sign-in cancelled."
            } catch AuthError.cancelled {
                status.stringValue = "Sign-in cancelled."
            } catch {
                status.stringValue = error.localizedDescription
            }
            setBusy(false)
        }
    }

    private func setBusy(_ busy: Bool) {
        signInButton.isEnabled = !busy
        codeButton.isEnabled = !busy
        cancelButton.isHidden = !busy
    }
}
