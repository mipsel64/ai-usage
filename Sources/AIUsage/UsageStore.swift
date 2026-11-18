import Foundation
import Observation
import QuotaCore
import UserNotifications

struct ProviderState {
    var connected = false
    var snapshot: QuotaSnapshot?
    var message: String?
    var loading = false
    var needsAuthentication = false
    var account: AccountIdentity?
}

struct ActionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor @Observable
final class UsageStore {
    let providers: [QuotaProvider]
    private let defaults: UserDefaults
    private let vault: any CredentialVaulting
    private let oauth: any SubscriptionOAuthDriving
    private let browserLogin: any ZaiBrowserLoginDriving
    private let now: () -> Date
    private(set) var states: [ProviderID: ProviderState] = [:]
    private var generations: [ProviderID: UUID] = [:]
    private var loadedAccounts: Set<ProviderID> = []
    private var accountTasks: [ProviderID: Task<Void, Never>] = [:]
    private var redeeming: Set<ProviderID> = []
    private(set) var notificationsEnabled: Bool
    private(set) var notificationStatus: String = ""

    init(
        providers: [QuotaProvider] = ProviderCatalog.all,
        defaults: UserDefaults = .standard,
        vault: (any CredentialVaulting)? = nil,
        oauth: (any SubscriptionOAuthDriving)? = nil,
        browserLogin: (any ZaiBrowserLoginDriving)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        PreferencesMigration.migrateIfNeeded(into: defaults)
        self.providers = providers
        self.defaults = defaults
        self.vault = vault ?? CredentialVault()
        self.oauth = oauth ?? SubscriptionOAuthController()
        self.browserLogin = browserLogin ?? ZaiBrowserLoginController()
        self.now = now
        notificationsEnabled = defaults.bool(forKey: "notify")
        for provider in providers {
            let id = provider.id
            let connected = defaults.bool(forKey: "connected.\(id.rawValue)")
            var state = ProviderState(connected: connected)
            if connected, let data = defaults.data(forKey: "account.\(id.rawValue)") {
                state.account = (try? JSONDecoder().decode(AccountIdentity.self, from: data))?.sanitized()
            }
            if connected, let data = defaults.data(forKey: "snapshot.\(id.rawValue)") {
                state.snapshot = try? JSONDecoder().decode(QuotaSnapshot.self, from: data)
                state.message = "Waiting for the next reading."
            }
            if connected, case .oauth = provider.connection,
               defaults.integer(forKey: "oauthVersion.\(id.rawValue)") != 1 {
                state.needsAuthentication = true
                state.message = "Reconnect with \(provider.displayName) to use direct OAuth."
            }
            states[id] = state
        }
    }

    func monitor() async {
        if notificationsEnabled { await updatePermissionStatus() }
        while !Task.isCancelled {
            await withTaskGroup(of: Void.self) { group in
                for provider in providers where states[provider.id]?.connected == true {
                    group.addTask { await self.refresh(provider.id) }
                }
            }
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
    }

    func connect(_ id: ProviderID, secret: String? = nil, executable: URL? = nil) async throws {
        guard let provider = providers.first(where: { $0.id == id }), !redeeming.contains(id) else { throw QuotaError.unavailable }
        let generation = generations[id]
        let firstReading: QuotaSnapshot?
        var connectionAccess: ProviderAccess?
        var signInAccount: AccountIdentity?
        switch provider.connection {
        case let .signedExecutable(requirement):
            guard let executable else { throw QuotaError.notConfigured }
            _ = try await Task.detached { try requirement.validate(executable) }.value
            firstReading = try await provider.read(.executable(executable))
            connectionAccess = .executable(executable)
            guard generation == generations[id], !redeeming.contains(id) else { throw QuotaError.unavailable }
            defaults.set(executable.path, forKey: "path.\(id.rawValue)")
        case .apiKey:
            guard let key = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
                  key.utf8.count <= 4096, key.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw ActionError("Enter a coding plan API key with no spaces or line breaks.")
            }
            firstReading = try await provider.read(.apiKey(key))
            connectionAccess = .apiKey(key)
            guard generation == generations[id], !redeeming.contains(id) else { throw QuotaError.unavailable }
            try vault.store(key, for: id)
        case .browserLogin:
            guard secret == nil, executable == nil else { throw QuotaError.notConfigured }
            let login = try await browserLogin.login(id)
            let key = login.key
            signInAccount = login.account?.sanitized()
            guard generation == generations[id], !redeeming.contains(id) else { throw QuotaError.unavailable }
            firstReading = try await provider.read(.apiKey(key))
            connectionAccess = .apiKey(key)
            guard generation == generations[id], !redeeming.contains(id) else { throw QuotaError.unavailable }
            try vault.store(key, for: id)
        case .oauth:
            guard secret == nil, executable == nil else { throw QuotaError.notConfigured }
            let tokens = try await oauth.login(id)
            guard generation == generations[id], !redeeming.contains(id) else { throw QuotaError.unavailable }
            let result = try await readOAuth(
                provider: provider,
                tokens: tokens,
                generation: generation,
                persistRefreshedTokens: false
            )
            firstReading = result.snapshot
            connectionAccess = .oauth(result.tokens)
            guard generation == generations[id], !redeeming.contains(id) else { throw QuotaError.unavailable }
            try vault.store(try Self.encode(tokens: result.tokens), for: id)
        }
        let connectedGeneration = UUID()
        generations[id] = connectedGeneration
        loadedAccounts.remove(id)
        accountTasks[id]?.cancel()
        accountTasks[id] = nil
        defaults.removeObject(forKey: "snapshot.\(id.rawValue)")
        defaults.removeObject(forKey: "account.\(id.rawValue)")
        defaults.set(true, forKey: "connected.\(id.rawValue)")
        if case .oauth = provider.connection {
            defaults.set(1, forKey: "oauthVersion.\(id.rawValue)")
        }
        if case .browserLogin = provider.connection, let signInAccount,
           let data = try? JSONEncoder().encode(signInAccount) {
            defaults.set(data, forKey: "account.\(id.rawValue)")
        }
        states[id] = ProviderState(connected: true, snapshot: firstReading, account: signInAccount)
        if let firstReading {
            defaults.set(try JSONEncoder().encode(firstReading), forKey: "snapshot.\(id.rawValue)")
        } else {
            await refresh(id)
        }
        if signInAccount == nil, let connectionAccess {
            startAccountRead(for: provider, access: connectionAccess, generation: connectedGeneration)
        }
    }

    func disconnect(_ id: ProviderID) async throws {
        guard let provider = providers.first(where: { $0.id == id }), !redeeming.contains(id) else { throw QuotaError.unavailable }
        switch provider.connection {
        case .apiKey, .browserLogin, .oauth: try vault.remove(id)
        default: break
        }
        generations[id] = UUID()
        loadedAccounts.remove(id)
        accountTasks[id]?.cancel()
        accountTasks[id] = nil
        for prefix in ["connected", "path", "snapshot", "oauthVersion", "account"] { defaults.removeObject(forKey: "\(prefix).\(id.rawValue)") }
        states[id] = ProviderState()
    }

    private func startAccountRead(for provider: QuotaProvider, access: ProviderAccess, generation: UUID?) {
        let id = provider.id
        guard let readAccount = provider.readAccount, generation == generations[id],
              states[id]?.connected == true, !loadedAccounts.contains(id) else { return }
        loadedAccounts.insert(id)
        accountTasks[id] = Task {
            let identity = await readAccount(access)?.sanitized()
            guard !Task.isCancelled, generation == generations[id], states[id]?.connected == true else { return }
            states[id]?.account = identity
        }
    }

    func accountReadTask(for id: ProviderID) -> Task<Void, Never>? {
        accountTasks[id]
    }

    private func access(for provider: QuotaProvider, interactive: Bool) async throws -> ProviderAccess {
        switch provider.connection {
        case .apiKey, .browserLogin: return .apiKey(try await vault.read(provider.id, interactive: interactive))
        case .oauth:
            let serialized = try await vault.read(provider.id, interactive: interactive)
            guard let data = serialized.data(using: .utf8),
                  let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data),
                  let valid = try? tokens.validated()
            else { throw QuotaError.notConfigured }
            return .oauth(valid)
        case .signedExecutable:
            guard let path = defaults.string(forKey: "path.\(provider.id.rawValue)") else { throw QuotaError.notConfigured }
            return .executable(URL(fileURLWithPath: path))
        }
    }

    private func readOAuth(
        provider: QuotaProvider,
        tokens: OAuthTokens,
        generation: UUID?,
        persistRefreshedTokens: Bool = true
    ) async throws -> (snapshot: QuotaSnapshot, tokens: OAuthTokens) {
        let valid = try await validOAuth(
            tokens,
            for: provider.id,
            generation: generation,
            persistRefreshedTokens: persistRefreshedTokens
        )
        do {
            return (try await provider.read(.oauth(valid)), valid)
        } catch QuotaError.unauthorized {
            guard generation == generations[provider.id] else { throw QuotaError.unavailable }
            let refreshed = try await oauth.refresh(valid, for: provider.id)
            guard generation == generations[provider.id] else { throw QuotaError.unavailable }
            _ = try refreshed.validated()
            if persistRefreshedTokens {
                try vault.store(try Self.encode(tokens: refreshed), for: provider.id)
            }
            return (try await provider.read(.oauth(refreshed)), refreshed)
        }
    }

    private func validOAuth(
        _ tokens: OAuthTokens,
        for id: ProviderID,
        generation: UUID?,
        persistRefreshedTokens: Bool = true
    ) async throws -> OAuthTokens {
        let tokens = try tokens.validated()
        guard tokens.needsRefresh(at: now()) else { return tokens }
        guard generation == generations[id] else { throw QuotaError.unavailable }
        let refreshed = try await oauth.refresh(tokens, for: id)
        guard generation == generations[id] else { throw QuotaError.unavailable }
        _ = try refreshed.validated()
        if persistRefreshedTokens {
            try vault.store(try Self.encode(tokens: refreshed), for: id)
        }
        return refreshed
    }

    private static func encode(tokens: OAuthTokens) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(tokens)
        guard let value = String(data: data, encoding: .utf8) else { throw VaultError.inaccessible }
        return value
    }

    func refresh(_ id: ProviderID, interactive: Bool = false) async {
        guard let provider = providers.first(where: { $0.id == id }), let state = states[id],
              state.connected, !state.loading else { return }
        let generation = generations[id]
        states[id]?.loading = true
        defer { if generation == generations[id] { states[id]?.loading = false } }
        do {
            let access = try await access(for: provider, interactive: interactive)
            guard generation == generations[id] else { return }
            let reading: QuotaSnapshot
            var readingAccess = access
            if case let .oauth(tokens) = access {
                let result = try await readOAuth(provider: provider, tokens: tokens, generation: generation)
                reading = result.snapshot
                readingAccess = .oauth(result.tokens)
            } else {
                reading = try await provider.read(access)
            }
            guard generation == generations[id] else { return }
            if let last = state.snapshot, reading.observedAt < last.observedAt, last.observedAt <= .now {
                throw QuotaError.invalidResponse
            }
            states[id]?.snapshot = reading
            states[id]?.message = nil
            states[id]?.needsAuthentication = false
            defaults.set(try JSONEncoder().encode(reading), forKey: "snapshot.\(id.rawValue)")
            if notificationsEnabled, let last = state.snapshot, reading.observedAt > last.observedAt {
                let reset = !reading.refreshedWindows(since: last).isEmpty
                let credit = last.resetCredits.flatMap { before in reading.resetCredits.map { $0.availableCount > before.availableCount } } ?? false
                if reset || credit { await postNotification(provider: provider, reset: reset, credit: credit) }
            }
            startAccountRead(for: provider, access: readingAccess, generation: generation)
        } catch {
            guard generation == generations[id] else { return }
            if case QuotaError.unauthorized = error { states[id]?.needsAuthentication = true }
            if case .oauth = provider.connection, case QuotaError.notConfigured = error { states[id]?.needsAuthentication = true }
            if case OAuthError.unauthorized = error { states[id]?.needsAuthentication = true }
            if case .oauth = provider.connection, case QuotaError.notConfigured = error {
                states[id]?.message = "Reconnect with \(provider.displayName) to use direct OAuth."
            } else {
                states[id]?.message = Self.safeMessage(error)
            }
        }
    }

    func redeemableCredit(_ id: ProviderID, at now: Date) -> ResetCredits? {
        guard let state = states[id], state.connected, !state.loading, state.message == nil,
              let snapshot = state.snapshot, (0..<150).contains(now.timeIntervalSince(snapshot.observedAt)),
              let credits = snapshot.resetCredits, credits.availableCount > 0, credits.nextID != nil,
              credits.nextExpiry.map({ $0 > now }) ?? true else { return nil }
        return credits
    }

    private func redeemOAuth(
        tokens: OAuthTokens,
        provider: QuotaProvider,
        redeem: @Sendable (ProviderAccess, String, String) async throws -> Redemption,
        creditID: String,
        key: String,
        generation: UUID?
    ) async throws -> Redemption {
        let valid = try await validOAuth(tokens, for: provider.id, generation: generation)
        do {
            return try await redeem(.oauth(valid), creditID, key)
        } catch QuotaError.unauthorized {
            guard generation == generations[provider.id] else { throw QuotaError.unavailable }
            let refreshed = try await oauth.refresh(valid, for: provider.id)
            guard generation == generations[provider.id] else { throw QuotaError.unavailable }
            _ = try refreshed.validated()
            try vault.store(try Self.encode(tokens: refreshed), for: provider.id)
            return try await redeem(.oauth(refreshed), creditID, key)
        }
    }

    func redeemReset(_ id: ProviderID, creditID: String) async throws -> String {
        guard let provider = providers.first(where: { $0.id == id }), case let .banked(_, redeem) = provider.reset,
              redeemableCredit(id, at: .now)?.nextID == creditID else {
            throw ActionError("Refresh the quota and check that this reset is still available.")
        }
        redeeming.insert(id)
        states[id]?.loading = true
        defer { redeeming.remove(id); states[id]?.loading = false }
        let access = try await access(for: provider, interactive: true)
        let intent = "intent.\(id.rawValue).\(creditID)"
        let key = defaults.string(forKey: intent) ?? UUID().uuidString
        defaults.set(key, forKey: intent)
        let outcome: Redemption
        do {
            if case let .oauth(tokens) = access {
                outcome = try await redeemOAuth(
                    tokens: tokens,
                    provider: provider,
                    redeem: redeem,
                    creditID: creditID,
                    key: key,
                    generation: generations[id]
                )
            } else {
                outcome = try await redeem(access, creditID, key)
            }
        } catch {
            let message = "Reset result unknown. Check the provider’s usage page before trying again."
            states[id]?.message = message
            throw ActionError(message)
        }
        defaults.removeObject(forKey: intent)
        states[id]?.loading = false
        await refresh(id)
        switch outcome {
        case .reset: return "The provider confirmed the reset."
        case .alreadyRedeemed: return "This reset was already redeemed."
        case .nothingToReset: return "The provider reports that no quota needs a reset."
        case .noCredit: return "The provider reports that no reset credit is available."
        }
    }

    func setNotifications(_ enabled: Bool) async {
        guard enabled else {
            notificationsEnabled = false
            defaults.set(false, forKey: "notify")
            notificationStatus = "Notifications are off."
            return
        }
        do {
            notificationsEnabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            defaults.set(notificationsEnabled, forKey: "notify")
            notificationStatus = notificationsEnabled ? "Notifications are on." : "Allow AI Usage in System Settings → Notifications."
        } catch { notificationStatus = "macOS could not enable notifications." }
    }

    private func updatePermissionStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus != .authorized && settings.authorizationStatus != .provisional {
            notificationsEnabled = false
            defaults.set(false, forKey: "notify")
            notificationStatus = "Allow AI Usage in System Settings → Notifications."
        }
    }

    private func postNotification(provider: QuotaProvider, reset: Bool, credit: Bool) async {
        await updatePermissionStatus()
        guard notificationsEnabled, states[provider.id]?.connected == true else { return }
        let content = UNMutableNotificationContent()
        content.title = provider.displayName
        if reset && credit { content.body = "Quota refreshed. A new reset credit is available." }
        else if reset { content.body = "Quota refreshed." }
        else { content.body = "A new reset credit is available." }
        do { try await UNUserNotificationCenter.current().add(.init(identifier: UUID().uuidString, content: content, trigger: nil)) }
        catch { notificationStatus = "macOS could not deliver the last notification." }
    }

    private static func safeMessage(_ error: any Error) -> String {
        if let error = error as? QuotaError { return error.localizedDescription }
        if let error = error as? ExecutableError { return error.localizedDescription }
        if let error = error as? VaultError { return error.localizedDescription }
        if let error = error as? OAuthError { return error.localizedDescription }
        return QuotaError.unavailable.localizedDescription
    }
}
