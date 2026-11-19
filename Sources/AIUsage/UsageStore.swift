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
    private let session: CredentialSession
    private let oauth: any SubscriptionOAuthDriving
    private let browserLogin: any ZaiBrowserLoginDriving
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
        let oauth = oauth ?? SubscriptionOAuthController()
        self.oauth = oauth
        session = CredentialSession(vault: vault ?? CredentialVault(), oauth: oauth, now: now)
        self.browserLogin = browserLogin ?? ZaiBrowserLoginController()
        notificationsEnabled = defaults.bool(forKey: "notify")
        for provider in providers {
            let id = provider.id
            let connected = defaults.bool(forKey: "connected.\(id.rawValue)")
            var state = ProviderState(connected: connected)
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

    /// Providers the menu lists: connected and not waiting for a new sign-in.
    var activeProviders: [QuotaProvider] {
        providers.filter { states[$0.id].map { $0.connected && !$0.needsAuthentication } ?? false }
    }

    var needsSignIn: Bool {
        states.values.contains { $0.connected && $0.needsAuthentication }
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
        let connectionAccess: ProviderAccess
        var signInAccount: AccountIdentity?
        switch provider.connection {
        case let .signedExecutable(requirement):
            guard let executable else { throw QuotaError.notConfigured }
            _ = try await Task.detached { try requirement.validate(executable) }.value
            connectionAccess = .executable(executable)
        case .apiKey:
            guard let key = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
                  key.utf8.count <= 4096, key.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw ActionError("Enter a coding plan API key with no spaces or line breaks.")
            }
            connectionAccess = .apiKey(key)
        case .browserLogin:
            guard secret == nil, executable == nil else { throw QuotaError.notConfigured }
            let login = try await browserLogin.login(id)
            signInAccount = login.account?.sanitized()
            connectionAccess = .apiKey(login.key)
        case .oauth:
            guard secret == nil, executable == nil else { throw QuotaError.notConfigured }
            connectionAccess = .oauth(try await oauth.login(id))
        }
        guard generation == generations[id], !redeeming.contains(id) else { throw QuotaError.unavailable }
        let firstReading = try await provider.read(connectionAccess)
        guard generation == generations[id], !redeeming.contains(id) else { throw QuotaError.unavailable }
        // A new sign-in replaces the stored credential only after its first reading succeeds.
        if case let .executable(url) = connectionAccess {
            defaults.set(url.path, forKey: "path.\(id.rawValue)")
        } else {
            try session.connect(connectionAccess, for: id)
        }
        let connectedGeneration = UUID()
        generations[id] = connectedGeneration
        loadedAccounts.remove(id)
        accountTasks[id]?.cancel()
        accountTasks[id] = nil
        defaults.removeObject(forKey: "snapshot.\(id.rawValue)")
        defaults.set(true, forKey: "connected.\(id.rawValue)")
        if case .oauth = provider.connection {
            defaults.set(1, forKey: "oauthVersion.\(id.rawValue)")
        }
        states[id] = ProviderState(connected: true, snapshot: firstReading, account: signInAccount)
        defaults.set(try JSONEncoder().encode(firstReading), forKey: "snapshot.\(id.rawValue)")
        if signInAccount == nil {
            startAccountRead(for: provider, access: connectionAccess, generation: connectedGeneration)
        }
    }

    func disconnect(_ id: ProviderID) async throws {
        guard let provider = providers.first(where: { $0.id == id }), !redeeming.contains(id) else { throw QuotaError.unavailable }
        switch provider.connection {
        case .apiKey, .browserLogin, .oauth: try session.disconnect(id)
        default: break
        }
        generations[id] = UUID()
        loadedAccounts.remove(id)
        accountTasks[id]?.cancel()
        accountTasks[id] = nil
        for prefix in ["connected", "path", "snapshot", "oauthVersion"] { defaults.removeObject(forKey: "\(prefix).\(id.rawValue)") }
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
        guard case .signedExecutable = provider.connection else {
            return try await session.access(for: provider, interactive: interactive)
        }
        guard let path = defaults.string(forKey: "path.\(provider.id.rawValue)") else { throw QuotaError.notConfigured }
        return .executable(URL(fileURLWithPath: path))
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
            let (reading, readingAccess) = try await session.withRenewal(access, for: id, provider.read)
            guard generation == generations[id] else { return }
            if let last = state.snapshot, reading.observedAt < last.observedAt, last.observedAt <= .now {
                throw QuotaError.invalidResponse
            }
            states[id]?.snapshot = reading
            states[id]?.message = session.unsaved.contains(id) ? Self.unsavedSignIn : nil
            states[id]?.needsAuthentication = false
            defaults.set(try JSONEncoder().encode(reading), forKey: "snapshot.\(id.rawValue)")
            if notificationsEnabled, let last = state.snapshot, reading.observedAt > last.observedAt {
                let reset = !reading.refreshedWindows(since: last).isEmpty
                let credit = last.resetCredits.flatMap { before in reading.resetCredits.map { $0.availableCount > before.availableCount } } ?? false
                let low = reading.lowWindows(since: last)
                if reset || credit || !low.isEmpty {
                    await postNotification(provider: provider, generation: generation, body: Self.notificationBody(reset: reset, credit: credit, low: low))
                }
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
            outcome = try await session.withRenewal(access, for: id) { try await redeem($0, creditID, key) }.value
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

    static func notificationBody(reset: Bool, credit: Bool, low: [(window: QuotaWindow, threshold: Int)]) -> String {
        var lines: [String] = []
        if reset && credit { lines.append("Quota refreshed. A new reset credit is available.") }
        else if reset { lines.append("Quota refreshed.") }
        else if credit { lines.append("A new reset credit is available.") }
        lines += low.map { "\($0.window.title) limit is below \($0.threshold)%." }
        return lines.joined(separator: "\n")
    }

    private func postNotification(provider: QuotaProvider, generation: UUID?, body: String) async {
        await updatePermissionStatus()
        guard generation == generations[provider.id], notificationsEnabled, states[provider.id]?.connected == true else { return }
        let content = UNMutableNotificationContent()
        content.title = provider.displayName
        content.body = body
        do { try await UNUserNotificationCenter.current().add(.init(identifier: UUID().uuidString, content: content, trigger: nil)) }
        catch { notificationStatus = "macOS could not deliver the last notification." }
    }

    static let unsavedSignIn = "Could not save the renewed sign-in. A restart can require a new sign-in."

    private static func safeMessage(_ error: any Error) -> String {
        if let error = error as? ActionError { return error.message }
        if let error = error as? QuotaError { return error.localizedDescription }
        if let error = error as? ExecutableError { return error.localizedDescription }
        if let error = error as? VaultError { return error.localizedDescription }
        if let error = error as? OAuthError { return error.localizedDescription }
        return QuotaError.unavailable.localizedDescription
    }
}
