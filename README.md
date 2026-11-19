# AI Usage

[![macOS build and test](https://github.com/mipsel64/ai-usage/actions/workflows/ci.yml/badge.svg)](https://github.com/mipsel64/ai-usage/actions/workflows/ci.yml)

AI Usage is a native macOS menu bar app for Claude Code, Codex, Z.ai GLM Coding Plan, and Kimi Code. Click the gauge to see the reported quota windows and the time until each reset. No account is connected on first launch.

## Install

AI Usage needs macOS 14.4 or later on a Mac with Apple silicon.

1. Download `AI-Usage-<version>-arm64.dmg` and its `.sha256` file from the [latest release](https://github.com/mipsel64/ai-usage/releases/latest).
2. Optionally, check the download: in the download folder, run `shasum -a 256 -c AI-Usage-<version>-arm64.dmg.sha256`. The result must be `OK`.
3. Open the DMG and drag **AI Usage** to **Applications**.

The release is ad hoc signed and is not notarized by Apple, so macOS blocks the first open. To open it the first time:

- macOS 15 or later: open AI Usage once and click **Done** in the warning. Then choose Apple menu > **System Settings** > **Privacy & Security**, scroll to **Security**, click **Open Anyway** for AI Usage, and confirm with your login password.
- macOS 14: in Finder, Control-click AI Usage in Applications, choose **Open**, then click **Open** in the dialog.

After this, the app opens normally. See Apple's [Safely open apps on your Mac](https://support.apple.com/en-us/102445).

## Run

Use macOS 14.4 or later with the Swift 6 toolchain. Optionally, run `bash Packaging/setup-development-signing.sh` once. It creates a local **AI Usage Development** code-signing certificate in the login Keychain, so that rebuilds keep the same signing identity, and writes the ignored `.local.mk` file. Without it, builds use an ad-hoc signature. Run `make run` to build, sign, and open `.build/AI Usage.app`. Use the app bundle, not `swift run`, for macOS notifications. You can copy the bundle to `/Applications`. Run `make test` for the offline test suite. CI uses Xcode 26.5 (17F42).

Open **Preferences…** (⌘,) in the menu. You connect and sign in to providers only there: select a provider under **Subscriptions** and choose its connect action. Claude asks you to paste the authorization code shown after browser sign-in. Codex returns through a loopback callback. Kimi uses device authorization and shows its sign-in code while the app waits. Z.ai uses browser sign-in and creates its subscription credential automatically. When a provider needs a new sign-in, its sidebar row and the **Preferences…** menu row show an orange dot; choose **Sign In…** in its pane.

Click the gauge to see current quota and reset times. The menu lists only active subscriptions: connected providers that do not need a new sign-in. The app polls connected providers at launch and approximately once a minute while running. You can also refresh a provider from the menu. Failed reads do not refill quota: the menu keeps the last reading with its observation time. A missing reset date means the provider did not report one.

OAuth tokens and the Z.ai subscription key are stored in private files under `~/.config/aiusage`. Direct OAuth reuses the providers’ CLI client configuration. Provider terms and undocumented endpoints can change. AI Usage reports endpoint failures and does not substitute estimated quota. The **System** section of the sidebar has three panes: **General** turns on **Open AI Usage at login** (macOS can ask you to approve the login item in System Settings > General > Login Items), **Notifications** turns on alerts, and **About** shows the version.

The menu and account controls use native Liquid Glass on macOS 26 and later. With Reduce Transparency enabled, or on earlier supported versions, the app uses bordered controls.

| Provider | Subscription authentication | Manual reset |
|---|---|---|
| Claude | Choose **Connect with Claude** and complete browser OAuth. Paste the returned `code#state` value into AI Usage. The app reads the Claude Code OAuth usage endpoint. | Open [Claude Usage](https://claude.ai/settings/usage) from the menu. Eligible accounts can confirm **Reset for free** there. |
| Codex | Choose **Connect with Codex** and complete browser OAuth. AI Usage listens on `127.0.0.1:1455` for the callback, then reads account-scoped usage directly. | Confirm redemption of one identified, free banked reset in the app. If no eligible credit ID is reported, use the [Codex usage dashboard](https://chatgpt.com/codex/settings/usage). |
| Z.ai | Choose **Connect with Z.ai** and complete browser sign-in. AI Usage captures the `zcode://` callback automatically and restores the previous URL handler. A branded paste dialog remains available as a fallback. The app creates an **AI Usage** subscription key and stores it in its private credential file. | Open the [subscription page](https://z.ai/manage-apikey/subscription). The app reports available five-hour and weekly reset-card counts and the nearest expiry. Redeem cards only on the provider site; availability depends on the account and campaign. |
| Kimi | Choose **Connect with Kimi**, open the device-authorization page, and confirm the displayed code. AI Usage polls until authorization finishes or expires. | Kimi documents automatic resets. The menu links to the [Kimi Code Console](https://www.kimi.com/code/console); an Extra Usage purchase is not a reset. |

### Subscription renewal date

The **Account** section of a provider in **Preferences…** shows the date at which the subscription period ends, as the provider reports it. AI Usage does not calculate this date.

- Codex: **Current period ends**, from the `chatgpt_subscription_active_until` claim of the sign-in token. The token keeps this value until the sign-in renews.
- Z.ai: **Renews** or **Ends** (**Current period ends** when Z.ai does not say), from `nextRenewTime` and `autoRenew` of the active Coding Plan in the subscription list, the same read-only call that the official ZCode client makes with the subscription key.
- Claude and Kimi do not report a renewal date, so their section has no date row.

A missing row means that the provider did not report a date, or that the date has passed. After a reported date passes, AI Usage reads the account again, hourly at first and less often the longer the date stays in the past.

### Notifications

The initial reading establishes a baseline. A fresh observation can show that a window advanced past its previous deadline, that quota returned to full, or that the reported number of banked reset credits increased. AI Usage sends one local notification per provider observation. A ticking countdown, failed request, or visit to a reset page does not produce a reset alert. A notification cannot identify changes that occur and disappear between observations. No background service runs after you quit.

Low-quota alerts name each window that goes below 20% or 10% remaining, once per downward crossing. The first reading after you connect is the baseline, and after a relaunch the reading saved before the app quit is the baseline. A window that rises above a threshold and falls below it again alerts again.

### Sign-in renewal

AI Usage renews an OAuth sign-in (Claude, Codex, Kimi) when the access token expires in 5 minutes or less, and once after the provider rejects an access token. After such a forced renewal, the app makes no second one for that provider for 5 minutes unless you refresh that provider from the menu; a rejected access token in that time shows **Sign-in required**. Only one renewal runs at a time for each provider. Token requests wait up to 30 seconds; quota reads keep their shorter limit. The app keeps the new tokens in memory first and then saves them. If the save fails, the app continues with the tokens in memory, tries the save again at each later check, and shows a message on the provider card. If the provider refuses the refresh token permanently, the card shows **Sign-in required**, and automatic attempts stop until you refresh that provider from the menu or sign in again. If a renewal fails for a temporary reason while the access token is still valid, the quota check runs with that token; in all temporary cases the app tries the renewal again at the next check.

Some limits are outside the app. Claude ends a sign-in about 30 days after you sign in; renewal does not extend it. Users report this; Anthropic does not document it, and no official Claude source exists for these renewal rules. Codex and Kimi refresh tokens are reported to expire after about 30 days without use. Renewal runs only while the app runs. Z.ai uses a durable subscription key that needs no renewal; if Z.ai rejects the key, the card shows **Sign-in required**.

### Security

The default build is local, ad-hoc signed with the hardened runtime. It is not notarized or App Sandbox restricted. The Codex CLI uses its own sign-in and runs with your user permissions. The app verifies its OpenAI Developer ID signature before use. The release DMG is built the same way: ad hoc signed with the hardened runtime and not notarized. The app has no automatic updater; to update, install the DMG of a newer release.
Local builds use the stable self-signed **AI Usage Development** identity after `bash Packaging/setup-development-signing.sh`; without it, they use an ad-hoc signature. They use the hardened runtime and are not notarized or restricted by the App Sandbox. OAuth sign-in uses PKCE and state validation where supported. AI Usage keeps each credential in one file, `~/.config/aiusage/<provider id>`, with mode 0600. Each save writes a temporary file, flushes it to disk, and then renames it over the credential file. The app creates the directory with mode 0700, refuses it if it is a symlink or is not owned by your user, and resets group or other permissions on it to 0700. When the app creates the directory, it tries to exclude it from Time Machine backups and to add a `.gitignore` file that contains `*`, so that a `~/.config` kept in a dotfiles Git repository does not commit the credentials. Codex account IDs stay with the Codex tokens. Each process that runs as your macOS user can read these files without a dialog. The app refuses a credential file that is a symlink, is not a regular file, is not owned by your user, is readable by group or others, or is larger than 64 KiB. If you delete the file of an OAuth provider while the app runs, the app does not write it back (unless it still retries a failed save); it uses the tokens in memory until the next renewal, and then the card shows **Sign-in required**. A Z.ai key stays in memory until the app quits. A credential that an earlier version kept in the login Keychain moves to its file at the first read, and the app then deletes the Keychain item. If you connect or disconnect while that move waits for a Keychain dialog, the move does not overwrite the newer state. If macOS refuses that read in the background, the provider card asks you to refresh that provider from the menu; this can show one Keychain dialog. Automatic checks read the Keychain only when a credential file is missing, so after the move they do not read it again; the app asks macOS not to show a dialog for that read, but macOS can still show one for a build whose code signature changed. The app uses fixed first-party HTTPS endpoints, denies redirects, and does not collect analytics. Disconnect first deletes the old Keychain item and then the credential file; if the Keychain delete fails, the disconnect fails with a message and nothing changes. Disconnect does not revoke the provider’s OAuth grant or subscription key. Use the provider console to revoke access. Preferences contain connection choices and the last normalized quota observation, not tokens or raw responses. Account details stay in memory for the current session only; Z.ai reports them only at sign-in, so after a relaunch its details show again only after a reconnect, and disconnect removes them. The app has no automatic updater.

[AGENT.md](AGENT.md) describes how to register a new `QuotaProvider` without changing the menu, polling, or notifications. Adapters are compiled into the app; it does not load external plug-ins.

### Provider references

- [Claude OAuth client reference](https://github.com/badlogic/pi-mono/blob/main/packages/ai/src/auth/oauth/anthropic.ts), [Claude limit resets](https://support.claude.com/en/articles/17007452-what-is-a-limit-reset), and the undocumented [OAuth usage endpoint contract](https://github.com/FullFran/claudeops-tui/blob/main/docs/oauth-usage-endpoint.md)
- [Codex OAuth login](https://github.com/openai/codex/tree/main/codex-rs/login), [usage and reset-credit client](https://github.com/openai/codex/blob/main/codex-rs/backend-client/src/client/rate_limit_resets.rs), and [banked reset rules](https://help.openai.com/en/articles/20001498-how-resets-work-in-codex)
- [Z.ai browser sign-in and key provisioning](https://github.com/can1357/oh-my-pi/blob/main/packages/ai/src/registry/oauth/zai.ts), [quota rules and reset cards](https://docs.z.ai/devpack/faq). [OpenUsage](https://openusage.sh/docs/providers/zai/) and [zquota](https://netspeedy.github.io/zquota/windows/) verify the weekly `unit: 6, number: 1` monitor entry. [zai-usage](https://github.com/LogicIncZo/zai-usage) verifies the read-only reset-list endpoint, availability flags, and UTC+8 expiry strings. These endpoint contracts are not published stable APIs.
- [Kimi membership limits](https://www.kimi.com/code/docs/en/kimi-code/membership) and the [official CLI usage reader](https://github.com/MoonshotAI/kimi-code/blob/main/packages/oauth/src/managed-usage.ts)
- [Claude OAuth profile request](https://github.com/sirmalloc/ccstatusline/blob/main/src/utils/usage-fetch.ts) and the [profile response fields used by Claude Code](https://clawdipedia.cc/how-it-works/account-and-access)
- [Codex token renewal and refresh error classes](https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/manager.rs) and [Kimi token renewal and refresh errors](https://github.com/MoonshotAI/kimi-cli/blob/main/src/kimi_cli/auth/oauth.py)
- [Codex ID-token email and plan decoding](https://github.com/openai/codex/blob/main/codex-rs/login/src/token_data.rs), [organization claims requested by the official login](https://github.com/openai/codex/blob/main/codex-rs/login/src/server.rs), and the [organization title shape](https://github.com/openai/codex/issues/13007)
- [Z.ai sign-in user fields](https://github.com/zai-org/ZCode/blob/main/packages/services/src/oauth/providers/zaiProviderAdapter.ts) and [customer organization name](https://github.com/zai-org/ZCode/blob/main/packages/shared/src/project-access-token-client.ts)
- [Kimi managed account profile endpoint and fields](https://github.com/MoonshotAI/kimi-code/blob/main/packages/oauth/src/managed-userinfo.ts)
