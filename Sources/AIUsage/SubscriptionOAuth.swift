import AppKit
import Foundation
import Network
import QuotaCore

@MainActor
protocol SubscriptionOAuthDriving {
    func login(_ id: ProviderID) async throws -> OAuthTokens
    func refresh(_ tokens: OAuthTokens, for id: ProviderID) async throws -> OAuthTokens
}

protocol OAuthBrowserOpening {
    func open(_ url: URL) -> Bool
}

@MainActor
protocol OAuthDevicePromptClosing {
    func close()
}

@MainActor
protocol OAuthPrompting {
    func requestAuthorizationCode() throws -> String
    func requestZaiAuthorization() throws -> String
    func showDeviceAuthorization(_ device: KimiDeviceAuthorization) -> any OAuthDevicePromptClosing
}

struct SystemOAuthBrowser: OAuthBrowserOpening {
    func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
}

@MainActor
final class NativeOAuthPrompt: OAuthPrompting {
    func requestAuthorizationCode() throws -> String {
        try AuthorizationCodeDialog.claude()
    }

    func showDeviceAuthorization(_ device: KimiDeviceAuthorization) -> any OAuthDevicePromptClosing {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 170),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Sign in to Kimi"
        panel.isReleasedWhenClosed = false
        let message = NSTextField(wrappingLabelWithString: "Enter this code in the browser. This window closes when authorization finishes.")
        message.frame = NSRect(x: 20, y: 112, width: 420, height: 38)
        let code = NSTextField(labelWithString: device.userCode)
        code.font = .monospacedSystemFont(ofSize: 24, weight: .semibold)
        code.isSelectable = true
        code.frame = NSRect(x: 20, y: 64, width: 420, height: 34)
        let link = NSTextField(labelWithString: device.verificationCompleteURL.absoluteString)
        link.isSelectable = true
        link.lineBreakMode = .byTruncatingMiddle
        link.frame = NSRect(x: 20, y: 24, width: 420, height: 24)
        panel.contentView?.addSubview(message)
        panel.contentView?.addSubview(code)
        panel.contentView?.addSubview(link)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        return NativeDevicePrompt(panel: panel)
    }
}

@MainActor
private final class NativeDevicePrompt: OAuthDevicePromptClosing {
    private let panel: NSPanel
    init(panel: NSPanel) { self.panel = panel }
    func close() { panel.close() }
}

@MainActor
final class SubscriptionOAuthController: SubscriptionOAuthDriving {
    private let transport: any RemoteUsageTransport
    private let browser: any OAuthBrowserOpening
    private let prompts: any OAuthPrompting
    private let now: () -> Date

    init(
        transport: (any RemoteUsageTransport)? = nil,
        browser: any OAuthBrowserOpening = SystemOAuthBrowser(),
        prompts: any OAuthPrompting = NativeOAuthPrompt(),
        now: @escaping () -> Date = Date.init
    ) {
        self.transport = transport ?? SubscriptionOAuthTokens.defaultTransport()
        self.browser = browser
        self.prompts = prompts
        self.now = now
    }

    func login(_ id: ProviderID) async throws -> OAuthTokens {
        switch id {
        case .claude: return try await loginClaude()
        case .codex: return try await loginCodex()
        case .kimi: return try await loginKimi()
        default: throw OAuthError.unauthorized
        }
    }

    func refresh(_ tokens: OAuthTokens, for id: ProviderID) async throws -> OAuthTokens {
        try await SubscriptionOAuthTokens.refresh(tokens, provider: id, transport: transport, now: now())
    }

    private func loginClaude() async throws -> OAuthTokens {
        let pkce = OAuthPKCE.generate()
        let state = OAuthPKCE.randomState()
        let url = try ClaudeOAuth.authorizationURL(pkce: pkce, state: state)
        guard browser.open(url) else { throw OAuthError.unavailable }
        let input = try prompts.requestAuthorizationCode()
        try Task.checkCancellation()
        let authorization = try ClaudeOAuth.parseAuthorizationInput(input, expectedState: state)
        return try await ClaudeOAuth.exchange(
            code: authorization.code,
            state: authorization.state,
            pkce: pkce,
            transport: transport,
            now: now()
        )
    }

    private func loginCodex() async throws -> OAuthTokens {
        let listener = try LoopbackOAuthListener()
        try await listener.start()
        defer { listener.cancel() }
        let pkce = OAuthPKCE.generate()
        let state = OAuthPKCE.randomState()
        let url = try CodexOAuth.authorizationURL(pkce: pkce, state: state)
        listener.prepare(expectedState: state)
        guard browser.open(url) else { throw OAuthError.unavailable }
        let code = try await listener.waitForCode(expectedState: state)
        try Task.checkCancellation()
        return try await CodexOAuth.exchange(code: code, pkce: pkce, transport: transport, now: now())
    }

    private func loginKimi() async throws -> OAuthTokens {
        let device = try await KimiOAuth.startDeviceAuthorization(transport: transport)
        guard browser.open(device.verificationCompleteURL) else { throw OAuthError.unavailable }
        let prompt = prompts.showDeviceAuthorization(device)
        defer { prompt.close() }
        return try await KimiOAuth.poll(device: device, transport: transport)
    }
}

enum LoopbackCallbackParse: Equatable {
    case code(String)
    case denied
    case invalid
}

/// One fixed-port, loopback-only OAuth listener. Only the path and validated code are accepted;
/// callback URLs, response bodies, and tokens are never logged.
final class LoopbackOAuthListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.aiusage.oauth-loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var callbackContinuation: CheckedContinuation<String, Error>?
    private var pendingCallback: Result<String, Error>?
    private var finished = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 1455)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        guard let listener else { throw OAuthError.unavailable }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.start(with: .success(()))
            case .failed:
                self.start(with: .failure(OAuthError.unavailable))
            case .cancelled:
                self.start(with: .failure(CancellationError()))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(connection, initial: Data())
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                startContinuation = continuation
                lock.unlock()
                listener.start(queue: queue)
            }
        } onCancel: {
            cancel()
        }
    }

    func prepare(expectedState: String) {
        expectedCallbackState = expectedState
    }

    func waitForCode(expectedState: String) async throws -> String {
        prepare(expectedState: expectedState)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let pendingCallback {
                    self.pendingCallback = nil
                    lock.unlock()
                    continuation.resume(with: pendingCallback)
                    return
                }
                if finished {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                callbackContinuation = continuation
                lock.unlock()
                queue.asyncAfter(deadline: .now() + 10 * 60) { [weak self] in
                    self?.finish(with: .failure(OAuthError.timedOut))
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        start(with: .failure(CancellationError()))
        finish(with: .failure(CancellationError()))
        lock.lock()
        let listener = self.listener
        self.listener = nil
        lock.unlock()
        listener?.cancel()
    }

    private func start(with result: Result<Void, Error>) {
        lock.lock()
        let continuation = startContinuation
        startContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func finish(with result: Result<String, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let continuation = callbackContinuation
        callbackContinuation = nil
        if continuation == nil {
            pendingCallback = result
        }
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func receive(_ connection: NWConnection, initial: Data) {
        lock.lock()
        let active = !finished
        lock.unlock()
        guard active else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receiveChunk(connection, accumulated: initial)
    }

    private func receiveChunk(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var requestData = accumulated
            if let data { requestData.append(data) }
            guard error == nil, requestData.count <= 16 * 1024 else {
                Self.respond(connection, status: "400 Bad Request", body: "Invalid request") { connection.cancel() }
                return
            }
            if isComplete && data == nil {
                connection.cancel()
                return
            }
            if let headerEnd = requestData.range(of: Data([13, 10, 13, 10])) ?? requestData.range(of: Data([10, 10])) {
                let headers = requestData.prefix(headerEnd.lowerBound)
                let request = String(decoding: headers, as: UTF8.self)
                self.handle(request, connection: connection)
            } else if requestData.count == 16 * 1024 {
                Self.respond(connection, status: "400 Bad Request", body: "Invalid request") { connection.cancel() }
            } else {
                self.receiveChunk(connection, accumulated: requestData)
            }
        }
    }

    private func handle(_ request: String, connection: NWConnection) {
        // State verification is performed against the value installed before browser opening.
        // A valid early result is retained by finish(with:) until the waiter starts.
        guard let expectedState = expectedCallbackState else {
            Self.respond(connection, status: "400 Bad Request", body: "Invalid callback") { connection.cancel() }
            return
        }
        switch Self.parse(request, expectedState: expectedState) {
        case let .code(code):
            Self.respond(connection, status: "200 OK", body: "Sign-in complete. Return to AI Usage.") { [weak self] in
                connection.cancel()
                self?.finish(with: .success(code))
            }
        case .denied:
            Self.respond(connection, status: "400 Bad Request", body: "Sign-in was denied.") { [weak self] in
                connection.cancel()
                self?.finish(with: .failure(OAuthError.denied))
            }
        case .invalid:
            Self.respond(connection, status: "400 Bad Request", body: "Invalid callback") { connection.cancel() }
        }
    }

    private var expectedCallbackState: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return expectedStateStorage
        }
        set {
            lock.lock()
            expectedStateStorage = newValue
            lock.unlock()
        }
    }
    private var expectedStateStorage: String?

    private static func respond(
        _ connection: NWConnection,
        status: String,
        body: String,
        completion: @escaping @Sendable () -> Void
    ) {
        let payload = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + payload, completion: .contentProcessed { _ in completion() })
    }

    static func parse(_ request: String, expectedState: String) -> LoopbackCallbackParse {
        guard let line = request.components(separatedBy: .newlines).first,
              line.utf8.count <= 8192
        else { return .invalid }
        let pieces = line.split(separator: " ")
        guard pieces.count == 3, pieces[0] == "GET", pieces[2].hasPrefix("HTTP/") else { return .invalid }
        let target = String(pieces[1])
        guard target.utf8.count <= 8192, let components = URLComponents(string: target),
              components.path == "/auth/callback", components.fragment == nil
        else { return .invalid }
        let items = components.queryItems ?? []
        if items.contains(where: { $0.name == "error" }) { return .denied }
        guard items.filter({ $0.name == "code" }).count == 1,
              items.filter({ $0.name == "state" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value,
              !code.isEmpty, code.utf8.count <= 4096,
              code.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              let state = items.first(where: { $0.name == "state" })?.value,
              state == expectedState
        else { return .invalid }
        return .code(code)
    }
}
