import AppKit
import QuotaCore
import SwiftUI

private typealias DialogState<Value> = SwiftUI.State<Value>

@MainActor
final class ZaiCallbackRouter {
    static let shared = ZaiCallbackRouter()

    private var pendingURL: URL?
    private var handler: ((URL) -> Void)?

    func reset() {
        pendingURL = nil
        handler = nil
    }

    func receive(_ url: URL) {
        guard url.scheme?.lowercased() == "zcode" else { return }
        if let handler {
            handler(url)
        } else {
            pendingURL = url
        }
    }

    func listen(_ handler: @escaping (URL) -> Void) {
        self.handler = handler
        if let pendingURL {
            self.pendingURL = nil
            handler(pendingURL)
        }
    }

    func stopListening() {
        handler = nil
    }
}

@MainActor
enum AuthorizationCodeDialog {
    static func claude() throws -> String {
        try prompt(
            providerName: "Claude",
            instructions: "Complete sign-in in your browser, then paste the code and state shown by Anthropic.",
            placeholder: "code#state",
            automaticCallback: false
        )
    }

    static func zai() throws -> String {
        try prompt(
            providerName: "Z.ai",
            instructions: "Complete sign-in in your browser. AI Usage receives the callback automatically. If the browser shows an error page, copy its full address and paste it below.",
            placeholder: "zcode://zai-auth/callback?… or code#state",
            automaticCallback: true
        )
    }

    private static func prompt(
        providerName: String,
        instructions: String,
        placeholder: String,
        automaticCallback: Bool
    ) throws -> String {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: automaticCallback ? 294 : 254),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "AI Usage"
        panel.isReleasedWhenClosed = false

        var result: String?
        var modalActive = false
        let submit: (String) -> Void = { value in
            result = value
            if modalActive { NSApplication.shared.stopModal() }
            panel.close()
        }
        let cancel = {
            if modalActive { NSApplication.shared.stopModal() }
            panel.close()
        }
        let content = AuthorizationCodePromptView(
            providerName: providerName,
            instructions: instructions,
            placeholder: placeholder,
            automaticCallback: automaticCallback,
            submit: submit,
            cancel: cancel
        )
        let hosting = NSHostingView(rootView: content)
        panel.contentView = hosting
        panel.center()

        if automaticCallback {
            ZaiCallbackRouter.shared.listen { submit($0.absoluteString) }
        }
        defer {
            if automaticCallback { ZaiCallbackRouter.shared.stopListening() }
            panel.close()
        }

        guard result == nil else { return result! }
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        if let field = firstTextField(in: hosting) {
            panel.makeFirstResponder(field)
        }
        modalActive = true
        NSApplication.shared.runModal(for: panel)
        modalActive = false
        guard let result else { throw OAuthError.denied }
        return result
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        for child in view.subviews {
            if let field = firstTextField(in: child) { return field }
        }
        return nil
    }
}

struct AuthorizationCodePromptView: View {
    let providerName: String
    let instructions: String
    let placeholder: String
    let automaticCallback: Bool
    let submit: (String) -> Void
    let cancel: () -> Void

    @DialogState private var response = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                AIUsageAppIcon(size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Finish \(providerName) sign-in")
                        .font(.title3.weight(.semibold))
                    Text(automaticCallback ? "Waiting for the browser callback" : "Browser authorization")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(instructions)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Authorization response")
                    .font(.caption.weight(.medium))
                TextField(placeholder, text: $response)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit(submitResponse)
            }

            HStack {
                if automaticCallback {
                    Label("Automatic callback is ready", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: submitResponse)
                    .keyboardShortcut(.defaultAction)
                    .usageActionStyle(prominent: true)
                    .disabled(response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func submitResponse() {
        let value = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        submit(value)
    }
}
