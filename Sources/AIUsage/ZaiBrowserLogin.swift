import AppKit
import Foundation
import QuotaCore

@MainActor
protocol ZaiBrowserLoginDriving {
    func login(_ id: ProviderID) async throws -> String
}

@MainActor
final class ZaiURLSchemeCapture {
    private let callbackURL = URL(string: "zcode://zai-auth/callback")!
    private var previousAppURL: URL?
    private var captured = false

    func capture() async {
        previousAppURL = NSWorkspace.shared.urlForApplication(toOpen: callbackURL)
        do {
            try await setDefaultHandler(Bundle.main.bundleURL)
            captured = true
        } catch {
            captured = false
        }
    }

    func restore() async {
        guard captured else { return }
        if let previousAppURL, previousAppURL != Bundle.main.bundleURL {
            try? await setDefaultHandler(previousAppURL)
        }
        captured = false
    }

    private func setDefaultHandler(_ appURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "zcode") { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

@MainActor
final class ZaiBrowserLoginController: ZaiBrowserLoginDriving {
    private let transport: any RemoteUsageTransport
    private let browser: any OAuthBrowserOpening
    private let prompts: any OAuthPrompting
    private let makeState: () -> String

    init(
        transport: (any RemoteUsageTransport)? = nil,
        browser: any OAuthBrowserOpening = SystemOAuthBrowser(),
        prompts: any OAuthPrompting = NativeOAuthPrompt(),
        makeState: @escaping () -> String = OAuthPKCE.randomState
    ) {
        self.transport = transport ?? RemoteUsage.defaultTransport()
        self.browser = browser
        self.prompts = prompts
        self.makeState = makeState
    }

    func login(_ id: ProviderID) async throws -> String {
        guard id == .zai else { throw QuotaError.notConfigured }
        try Task.checkCancellation()
        ZaiCallbackRouter.shared.reset()
        defer { ZaiCallbackRouter.shared.reset() }
        let state = makeState()
        let url = try ZaiOAuth.authorizationURL(state: state)
        let schemeCapture = ZaiURLSchemeCapture()
        await schemeCapture.capture()
        let input: String
        do {
            guard browser.open(url) else { throw OAuthError.unavailable }
            input = try prompts.requestZaiAuthorization()
        } catch {
            await schemeCapture.restore()
            throw error
        }
        await schemeCapture.restore()
        try Task.checkCancellation()
        let authorization = try ZaiOAuth.parseAuthorizationInput(input, expectedState: state)
        return try await ZaiOAuth.exchange(
            code: authorization.code,
            state: authorization.state,
            transport: transport
        )
    }
}

extension NativeOAuthPrompt {
    func requestZaiAuthorization() throws -> String {
        try AuthorizationCodeDialog.zai()
    }
}
