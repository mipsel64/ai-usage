import Foundation
import QuotaCore

/// The only reader and writer of stored credentials: keeps them in memory for the launch and renews OAuth tokens.
@MainActor
final class CredentialSession {
    static let renewalFailure = "Cannot renew the sign-in now. AI Usage tries again at the next refresh."

    private let vault: any CredentialVaulting
    private let oauth: any SubscriptionOAuthDriving
    private let now: () -> Date
    private var cache: [ProviderID: ProviderAccess] = [:]
    private var renewals: [ProviderID: (id: UUID, task: Task<OAuthTokens, any Error>)] = [:]
    private var connections: [ProviderID: UUID] = [:]
    /// Providers whose renewed tokens are only in memory because the vault did not store them.
    private(set) var unsaved: Set<ProviderID> = []
    /// Providers whose refresh token the provider refused; only an interactive use tries again.
    private(set) var refused: Set<ProviderID> = []
    /// When a renewal after a 401 last started. A pause covers a renewal that runs or succeeded, so a provider that
    /// rejects fresh tokens gets no renewal storm; a temporary failure clears it, so the next use renews again.
    private var forcedRenewals: [ProviderID: Date] = [:]

    init(vault: any CredentialVaulting, oauth: any SubscriptionOAuthDriving, now: @escaping () -> Date) {
        self.vault = vault
        self.oauth = oauth
        self.now = now
    }

    /// Stores the credential of a new connection and discards everything from the previous one.
    func connect(_ access: ProviderAccess, for id: ProviderID) throws {
        let value: String
        switch access {
        case let .apiKey(key): value = key
        case let .oauth(tokens): value = try Self.encode(tokens)
        case .executable: throw QuotaError.notConfigured
        }
        try vault.store(value, for: id)
        discard(id)
    }

    func disconnect(_ id: ProviderID) throws {
        try vault.remove(id)
        discard(id)
    }

    /// Returns the stored credential and renews OAuth tokens inside the renewal lead time.
    func access(for provider: QuotaProvider, interactive: Bool) async throws -> ProviderAccess {
        let id = provider.id
        if interactive {
            refused.remove(id)
            forcedRenewals[id] = nil
        } else if refused.contains(id) {
            throw OAuthError.unauthorized
        }
        let access = try await cached(provider, interactive: interactive)
        retrySave(id)
        guard case let .oauth(tokens) = access, tokens.needsRefresh(at: now()) else { return access }
        do {
            return .oauth(try await renew(tokens, for: id))
        } catch is ActionError where tokens.expiresAt > now() {
            // A temporary renewal failure inside the lead time leaves room to read with the current token.
            return access
        }
    }

    /// Runs `operation`, and after a 401 runs it once more with renewed OAuth tokens.
    /// Automatic uses renew this way at most once per lead time after a forced renewal that succeeded or is running,
    /// so a provider that rejects fresh tokens causes no storm. A temporary renewal failure starts no pause.
    func withRenewal<T>(
        _ access: ProviderAccess,
        for id: ProviderID,
        _ operation: (ProviderAccess) async throws -> T
    ) async throws -> (value: T, access: ProviderAccess) {
        let connection = connections[id]
        do {
            return (try await operation(access), access)
        } catch QuotaError.unauthorized {
            // Never run the operation again with the tokens of a different connection.
            guard connection == connections[id] else { throw QuotaError.unavailable }
            guard case let .oauth(rejected) = access, case let .oauth(current)? = cache[id] else {
                throw QuotaError.unauthorized
            }
            let tokens: OAuthTokens
            if current == rejected {
                if let last = forcedRenewals[id], now().timeIntervalSince(last) < OAuthTokens.refreshLeadTime {
                    throw QuotaError.unauthorized
                }
                forcedRenewals[id] = now()
                do {
                    tokens = try await renew(rejected, for: id)
                } catch let error as ActionError {
                    forcedRenewals[id] = nil
                    throw error
                }
                guard connection == connections[id] else { throw QuotaError.unavailable }
            } else {
                tokens = current
            }
            let renewed = ProviderAccess.oauth(tokens)
            return (try await operation(renewed), renewed)
        }
    }

    private func cached(_ provider: QuotaProvider, interactive: Bool) async throws -> ProviderAccess {
        let id = provider.id
        if let access = cache[id] { return access }
        let connection = connections[id]
        let value = try await vault.read(id, interactive: interactive)
        guard connection == connections[id] else { throw QuotaError.unavailable }
        if let access = cache[id] { return access }
        let access: ProviderAccess
        if case .oauth = provider.connection {
            guard let tokens = Self.decode(value) else { throw QuotaError.notConfigured }
            access = .oauth(tokens)
        } else {
            access = .apiKey(value)
        }
        cache[id] = access
        return access
    }

    /// Concurrent callers share one renewal; it runs in its own task, so a cancelled caller does not lose it.
    private func renew(_ tokens: OAuthTokens, for id: ProviderID) async throws -> OAuthTokens {
        if let renewal = renewals[id] { return try await renewal.task.value }
        let renewalID = UUID()
        let task = Task { try await self.performRenewal(of: tokens, for: id, renewalID: renewalID) }
        renewals[id] = (renewalID, task)
        return try await task.value
    }

    private func performRenewal(of current: OAuthTokens, for id: ProviderID, renewalID: UUID) async throws -> OAuthTokens {
        defer { if renewals[id]?.id == renewalID { renewals[id] = nil } }
        // shortcut: two app instances can still renew at the same time, add a file lock if that occurs.
        var tokens = current
        // Unsaved tokens in memory are newer than the vault, so the vault cannot replace them.
        if !unsaved.contains(id) {
            let stored: OAuthTokens?
            do {
                stored = try await storedTokens(id)
            } catch {
                // The credential was deleted: do not renew it and do not write it back.
                if renewals[id]?.id == renewalID { cache[id] = nil }
                throw error
            }
            guard renewals[id]?.id == renewalID else { throw QuotaError.unavailable }
            // Different stored tokens come from another app instance, which has already spent the refresh token in memory.
            if let stored, stored != tokens {
                cache[id] = .oauth(stored)
                if !stored.needsRefresh(at: now()) { return stored }
                tokens = stored
            }
        }
        let renewed: OAuthTokens
        do {
            renewed = try await oauth.refresh(tokens, for: id).validated()
        } catch OAuthError.unauthorized {
            if renewals[id]?.id == renewalID { refused.insert(id) }
            throw OAuthError.unauthorized
        } catch {
            throw ActionError(Self.renewalFailure)
        }
        guard renewals[id]?.id == renewalID else { throw QuotaError.unavailable }
        // The provider rotated the refresh token, so memory keeps the new one even if the vault refuses it.
        cache[id] = .oauth(renewed)
        unsaved.insert(id)
        retrySave(id)
        return renewed
    }

    /// Throws `QuotaError.notConfigured` when no credential is stored; returns nil when the vault cannot be read.
    private func storedTokens(_ id: ProviderID) async throws -> OAuthTokens? {
        do {
            return Self.decode(try await vault.read(id, interactive: false))
        } catch QuotaError.notConfigured {
            throw QuotaError.notConfigured
        } catch {
            return nil
        }
    }

    private func retrySave(_ id: ProviderID) {
        guard unsaved.contains(id), case let .oauth(tokens)? = cache[id],
              let value = try? Self.encode(tokens), (try? vault.store(value, for: id)) != nil else { return }
        unsaved.remove(id)
    }

    private func discard(_ id: ProviderID) {
        connections[id] = UUID()
        cache[id] = nil
        renewals[id] = nil
        unsaved.remove(id)
        refused.remove(id)
        forcedRenewals[id] = nil
    }

    private static func decode(_ value: String) -> OAuthTokens? {
        guard let data = value.data(using: .utf8),
              let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data) else { return nil }
        return try? tokens.validated()
    }

    private static func encode(_ tokens: OAuthTokens) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(tokens)
        guard let value = String(data: data, encoding: .utf8) else { throw VaultError.inaccessible }
        return value
    }
}
