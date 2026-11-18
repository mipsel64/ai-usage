# AI Usage agent guide

## Product contract

Build a native macOS menu bar app in Swift. The initial providers are Claude Code, Codex, Z.ai GLM Coding Plan, and Kimi Code. Show each reported quota window, the percentage remaining, the time until reset, and the age of the reading. If a provider omits a value, show that it is not available. Never substitute zero or invent a reset date.

A quota refresh reads data. A quota reset changes an account. Keep those actions separate. Use a provider site when the provider requires it. Do not label a site visit as a successful reset. Do not purchase quota. Only consume a named banked reset after explicit confirmation. Do not retry a write after a timeout. A local notification describes an observed change, not a prediction from the clock.

## Add a provider

1. Verify the quota endpoint or local protocol against provider documentation or maintained provider source. Confirm the account type, credential scope, units, reset time zone, and reset eligibility. Record the source in `README.md`.
2. Implement the reader in `Sources/QuotaCore`. Return `QuotaSnapshot` with stable window IDs, percentages in `0...100`, and the observation time. Use `nil` for an unknown reset time. Reject malformed responses. Never use transcript token counts as subscription quota.
3. Register one `QuotaProvider` in `ProviderCatalog.all`. Use a unique, permanent `ProviderID`. Supply the connection method, trusted account URL, read operation, and `ResetAction`. Use `.automaticOnly`, `.website`, or `.banked` as supported. With an existing connection method, no change is necessary in the menu, poller, persistence, or alert logic. Add a new connection method only if the trust boundary differs.
4. Add deterministic contract tests with synthetic inputs. Include partial windows, unit conversion, bad credentials, bad payloads, and reset capability as applicable. Never exercise a real account mutation in a test.

## Boundaries

- `Sources/QuotaCore`: adapters, data contracts, and reset detection. Keep SwiftUI and Keychain access out of this target.
- `Sources/AIUsage`: menu, connections, credentials, polling, local notifications, and user confirmation. The catalog supplies the provider list. Do not switch on provider names here.
- `Sources/ClaudeQuotaCapture`: project the Claude Code status-line stream to quota fields only. Never log or retain the raw payload.
- Keep API keys in the login Keychain. Do not read browser cookies, CLI token files, or another app’s Keychain items. Send each key only to its fixed provider endpoint. Reject redirects. Limit response size and time.
- Verify the selected executable against the provider’s signing requirement before launch. Do not run a shell or search `PATH`. Keep notifications and error messages free of private payloads.

## Work method

For independent provider changes, use subagents with separate file ownership. Agree on the contract first. Apply the matching ECC skill to each task: `agentic-engineering`, `swiftui-patterns`, `swift-protocol-di-testing`, `security-review`, or `verification-loop`. Use a fresh reviewer for changes to credentials or reset commands. For a GLM-5.3 security consultation, select `zai/glm-5.3` with `max` thinking. Send the design only; do not send credentials or local account data. Report the actual model and result.

Run `make test` and `make run`. Check the packaged menu with all providers disconnected before connecting a test account. Verify a new adapter with synthetic data first. Report exactly which live paths you checked. Do not claim a live quota reset from a fixture or a local cache update.
