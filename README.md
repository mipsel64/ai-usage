# AI Usage

[![macOS build and test](https://github.com/mipsel64/ai-usage/actions/workflows/ci.yml/badge.svg)](https://github.com/mipsel64/ai-usage/actions/workflows/ci.yml)

AI Usage is a native macOS menu bar app for Claude Code, Codex, Z.ai GLM Coding Plan, and Kimi Code. Click the gauge to see the reported quota windows and the time until each reset. No account is connected on first launch.

## Run

Use macOS 14.4 or later with the Swift 6 toolchain. Run `make run` to build, sign, and open `.build/AI Usage.app`. Use the app bundle, not `swift run`, for macOS notifications. You can copy the bundle to `/Applications`. Move it **before** you configure the Claude helper. Run `make test` for the offline test suite. CI uses Xcode 26.5 (17F42).

Open **Connections** in the menu. Enable individual providers and allow reset notifications if you want them. The app polls connected providers at launch and approximately once a minute while running. You can also refresh a provider from the menu. Failed reads do not refill quota: the menu keeps the last reading with its observation time. A missing reset date means the provider did not report one.

| Provider | Connect | Manual reset |
|---|---|---|
| Claude | Configure the bundled status-line helper in Claude Code, then enable the connection. | Open [Claude Usage](https://claude.ai/settings/usage) from the menu. Eligible accounts can confirm **Reset for free** there. |
| Codex | Sign in to the official Codex CLI with ChatGPT. Select the signed native `codex` executable, not a shell or npm wrapper. | Confirm redemption of one identified, free banked reset in the app. If the CLI does not report an eligible credit ID, use the [Codex usage dashboard](https://chatgpt.com/codex/settings/usage). |
| Z.ai | Enter an international GLM Coding Plan key. The reader uses `api.z.ai`, not the China endpoint. | Open the [subscription page](https://z.ai/manage-apikey/subscription). Five-hour or weekly reset cards depend on the account and campaign. |
| Kimi | Enter a Kimi Code membership key for `api.kimi.com`, not a Moonshot developer-platform key. | Kimi documents automatic resets. The menu links to the [Kimi Code Console](https://www.kimi.com/code/console); an Extra Usage purchase is not a reset. |

### Claude Code setup

Copy the helper command from Connections into the `statusLine` section of your Claude Code settings. Merge the section; do not replace the entire settings file. For a bundle installed in `/Applications`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "'/Applications/AI Usage.app/Contents/Helpers/claude-quota-capture'",
    "refreshInterval": 60
  }
}
```

To retain an existing status line, use `'<helper path>' --passthrough | <your existing command>`. Only pipe to a command you trust: it receives the original Claude status-line payload. The app never edits your Claude configuration. To stop capture, remove the helper from `statusLine`; disconnecting in AI Usage alone stops monitoring, not the external Claude hook. Remove `~/Library/Application Support/ai-usage/claude.json` to delete the helper’s last reading.

Use Claude Code after setup. Claude supplies rate limits for eligible sessions after an API response. The helper stores quota fields and an observation time only. An inactive CLI cannot supply a fresh reading. The Codex CLI must support `account/rateLimits/read` for quota and `account/rateLimitResetCredit/consume` for direct redemption.

### Reset notifications

The initial reading establishes a baseline. A fresh observation can show that a window advanced past its previous deadline, that quota returned to full, or that the reported number of banked reset credits increased. AI Usage sends one local notification per provider observation. A ticking countdown, failed request, or visit to a reset page does not produce a reset alert. A notification cannot identify changes that occur and disappear between observations. No background service runs after you quit.

### Security

The default build is local, ad-hoc signed with the hardened runtime. It is not notarized or App Sandbox restricted. The Codex CLI uses its own sign-in and runs with your user permissions. The app verifies its OpenAI Developer ID signature before use. The app has no automatic updater. For distribution, use a Developer ID identity (`make app SIGN_IDENTITY='Developer ID Application: …'`) and notarize the bundle separately.

Z.ai and Kimi keys stay in the local login Keychain. Coding keys may permit more than quota reads; use a dedicated, revocable key. The app uses fixed first-party HTTPS endpoints, denies redirects, and does not collect analytics. Disconnect removes the app’s saved key, not the provider’s key. To revoke it, use the provider console. Preferences contain connection choices and the last normalized quota observation, not tokens or raw responses. Rebuilding with a different signing identity may require new Keychain approval.

[AGENT.md](AGENT.md) describes how to register a new `QuotaProvider` without changing the menu, polling, or notifications. Adapters are compiled into the app; it does not load external plug-ins.

### Provider references

- [Claude Code status-line data](https://code.claude.com/docs/en/statusline) and [Claude limit resets](https://support.claude.com/en/articles/17007452-what-is-a-limit-reset)
- [Codex app-server protocol](https://learn.chatgpt.com/docs/app-server) and [banked reset rules](https://help.openai.com/en/articles/20001498-how-resets-work-in-codex)
- [Z.ai quota rules and reset cards](https://docs.z.ai/devpack/faq). The monitor endpoint is used by the dashboard and [a public quota reader](https://github.com/shaftoe/pi-zai-usage/blob/master/src/api.ts); its wire format is not a published stable API.
- [Kimi membership limits](https://www.kimi.com/code/docs/en/kimi-code/membership) and the [official CLI usage reader](https://github.com/MoonshotAI/kimi-code/blob/main/packages/oauth/src/managed-usage.ts)
