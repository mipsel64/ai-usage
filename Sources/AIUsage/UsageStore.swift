import Foundation
import Observation
import QuotaCore
import UserNotifications

struct ProviderState {
    var connected = false
    var snapshot: QuotaSnapshot?
    var message: String?
    var loading = false
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
    private(set) var states: [ProviderID: ProviderState] = [:]
    private var generations: [ProviderID: UUID] = [:]
    private var redeeming: Set<ProviderID> = []
    private(set) var notificationsEnabled: Bool
    private(set) var notificationStatus: String = ""

    init(providers: [QuotaProvider] = ProviderCatalog.all, defaults: UserDefaults = .standard) {
        self.providers = providers
        self.defaults = defaults
        notificationsEnabled = defaults.bool(forKey: "notify")
        for provider in providers {
            let id = provider.id
            let connected = defaults.bool(forKey: "connected.\(id.rawValue)")
            var state = ProviderState(connected: connected)
            if connected, let data = defaults.data(forKey: "snapshot.\(id.rawValue)") {
                state.snapshot = try? JSONDecoder().decode(QuotaSnapshot.self, from: data)
                state.message = "Waiting for the next reading."
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
        switch provider.connection {
        case .statusLine: break
        case let .signedExecutable(requirement):
            guard let executable else { throw QuotaError.notConfigured }
            let generation = generations[id]
            _ = try await Task.detached { try requirement.validate(executable) }.value
            guard generation == generations[id], !redeeming.contains(id) else { throw QuotaError.unavailable }
            defaults.set(executable.path, forKey: "path.\(id.rawValue)")
        case .apiKey:
            guard let key = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
                  key.utf8.count <= 4096, key.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw ActionError("Enter a coding plan API key with no spaces or line breaks.")
            }
            try CredentialVault.store(key, for: id)
        }
        generations[id] = UUID()
        defaults.removeObject(forKey: "snapshot.\(id.rawValue)")
        defaults.set(true, forKey: "connected.\(id.rawValue)")
        states[id] = ProviderState(connected: true)
        await refresh(id)
    }

    func disconnect(_ id: ProviderID) async throws {
        guard let provider = providers.first(where: { $0.id == id }), !redeeming.contains(id) else { throw QuotaError.unavailable }
        if case .apiKey = provider.connection { try CredentialVault.remove(id) }
        generations[id] = UUID()
        for prefix in ["connected", "path", "snapshot"] { defaults.removeObject(forKey: "\(prefix).\(id.rawValue)") }
        states[id] = ProviderState()
    }

    private func access(for provider: QuotaProvider) async throws -> ProviderAccess {
        switch provider.connection {
        case .statusLine: return .local
        case .apiKey: return .apiKey(try await CredentialVault.read(provider.id))
        case .signedExecutable:
            guard let path = defaults.string(forKey: "path.\(provider.id.rawValue)") else { throw QuotaError.notConfigured }
            return .executable(URL(fileURLWithPath: path))
        }
    }

    func refresh(_ id: ProviderID) async {
        guard let provider = providers.first(where: { $0.id == id }), let state = states[id],
              state.connected, !state.loading else { return }
        let generation = generations[id]
        states[id]?.loading = true
        defer { if generation == generations[id] { states[id]?.loading = false } }
        do {
            let access = try await access(for: provider)
            guard generation == generations[id] else { return }
            let reading = try await provider.read(access)
            guard generation == generations[id] else { return }
            if let last = state.snapshot, reading.observedAt < last.observedAt, last.observedAt <= .now {
                throw QuotaError.invalidResponse
            }
            states[id]?.snapshot = reading
            states[id]?.message = nil
            defaults.set(try JSONEncoder().encode(reading), forKey: "snapshot.\(id.rawValue)")
            if notificationsEnabled, let last = state.snapshot, reading.observedAt > last.observedAt {
                let reset = !reading.refreshedWindows(since: last).isEmpty
                let credit = last.resetCredits.flatMap { before in reading.resetCredits.map { $0.availableCount > before.availableCount } } ?? false
                if reset || credit { await postNotification(provider: provider, reset: reset, credit: credit) }
            }
        } catch {
            guard generation == generations[id] else { return }
            if case .statusLine = provider.connection {
                states[id]?.message = "No current status-line reading. Check setup and use \(provider.displayName)."
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
        let access = try await access(for: provider)
        let intent = "intent.\(id.rawValue).\(creditID)"
        let key = defaults.string(forKey: intent) ?? UUID().uuidString
        defaults.set(key, forKey: intent)
        let outcome: Redemption
        do {
            outcome = try await redeem(access, creditID, key)
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
        return QuotaError.unavailable.localizedDescription
    }
}
