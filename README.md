# CodexMeter

CodexMeter is a native macOS menu bar app that keeps your Codex account limits
visible at a glance.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black)
![Swift](https://img.shields.io/badge/Swift-5-orange)
![Version](https://img.shields.io/badge/version-1.7.0-blue)

> [!NOTE]
> CodexMeter is an unofficial community project. It is not affiliated with or
> endorsed by OpenAI.

The current development build is **1.7.1-dev (28)**, based on released
**1.7.0 (25)** and including native Usage Window Auto-start. The published
1.7.0 download does not contain this development feature.

## Preview

### Menu Bar Popover

<p align="center">
  <img src="docs/images/codexmeter-menu-bar-popover.png" width="380" alt="CodexMeter menu-bar popover showing five-hour and weekly quota, reset opportunities, quota history, and token activity">
</p>

### Usage History

<p align="center">
  <img src="docs/images/codexmeter-usage-history.png" width="900" alt="CodexMeter Usage History window showing browsable quota history and token activity">
</p>

### Interactive Token Activity

<p align="center">
  <img src="docs/images/codexmeter-token-activity.png" width="900" alt="CodexMeter interactive Token Activity chart with range selection and hover details">
</p>

### Customizable Popover

<p align="center">
  <img src="docs/images/codexmeter-popover-customization.png" width="560" alt="CodexMeter popover customization window with quota source, visibility, ordering, and live preview controls">
</p>

## Features

- Shows a selected Codex quota directly in the macOS menu bar, with automatic
  fallback to the quota with the lowest remaining percentage.
- Uses two concentric progress rings:
  - outer ring: remaining quota;
  - inner ring: remaining time before reset.
- Highlights normal, over-pace, and low-quota states without relying on color
  alone.
- Displays the standard 5-hour and weekly Codex quota windows by default, with
  reset countdowns and detailed progress bars.
- Shows available banked Codex rate-limit resets as one compact lifetime
  progress bar and expiration time per reset. This view is read-only and cannot
  redeem a reset.
- Compares remaining quota with remaining time to indicate whether consumption
  is on pace.
- Optionally starts the next five-hour usage window when it is idle by sending
  one very short Codex message. Automatic start is off by default, is scoped to
  the current account, and can be limited to a daily time range. The popover
  displays a status card with a compact automation switch, current window,
  remaining-time progress using the same metric bar and time color as other quota windows,
  plus the model and active hours. Detailed configuration and the manual
  **Start window now** action live in Settings.
- Refreshes quota on launch, every 10 seconds while the menu is open, every
  60 seconds in the background, after a Codex rate-limit update, and on manual
  request. Account checks and Token Activity polling stay at
  one-minute intervals. Failed automatic refreshes back off up to five minutes;
  unchanged token responses do not rewrite history.
- Detects Codex account changes and switches quota data without requiring an app
  restart.
- Supports standalone and npm-installed Codex CLI launchers by supplying common
  local runtime paths to the App Server child process.
- Preserves the last successful result and marks it as stale when refresh fails.
- Supports optional low-quota and over-pace notifications.
- Supports optional quota-replenishment reminders through Bark, Gotify,
  Telegram bots, and Discord webhooks, with independent channel switches,
  test messages, delivery status, bounded retries, and Keychain credential storage.
- Supports launch at login.
- Includes English, Simplified Chinese, and Traditional Chinese.
- Lets the app interface follow the system appearance or stay in Light or Dark
  mode independently.
- Offers ring, horizontal-bar, stacked-bar, percentage-only, and progress-only
  menu bar styles.
- Lets users independently show, hide, and reorder quota details, reset
  opportunities, Usage Window Auto-start, Quota History, and Token Activity in
  the popover. Each returned
  quota window has its own visibility switch, and the menu bar indicator can use
  a chosen window or the automatic lowest-remaining fallback. The default
  popover shows Usage Window Auto-start after the quota windows, followed by
  Reset Opportunities, Quota History, and Token Activity while
  keeping the GPT-Reserve weekly quota hidden.
- Includes developer options with presets, custom quota/time sliders, live
  preview, safe appearance controls,
  deterministic quota-state presets, JSON configuration export, and a one-click
  reset to the accepted 1.0 appearance. Developer-only test data can populate
  30 days of quota history and simulate an available app update.
- Records local quota history as changes plus 15-minute anchors. The full chart
  defaults to the current seven-day reset cycle and can also show the rolling
  last 7 days, 14 days, or month, plus browsable calendar weeks and months.
  Historical ranges show observed quota consumption across reset cycles and
  label incomplete totals as lower bounds instead of estimating missing use.
  Each reset cycle remains a separate smooth curve beginning at 100%, with long
  unrecorded periods visibly shaded.
- Shows a compact view of the current weekly quota cycle plus the last 30 days
  of token activity directly in the menu-bar popover. The full history window
  can switch token activity between 7 days, 30 days, 90 days, one year, and all
  locally retained data. One-year data is grouped by week and all-time data by
  month to remain readable. Token values use compact `k`, `M`, and `B` units
  instead of scientific notation.
- Keeps the menu-bar popover compact with divider-separated quota and token
  sections rather than nested card backgrounds.
- Provides a resizable, full-screen-capable history window with an integrated
  transparent title bar. Hovering a token bar smoothly highlights its bucket,
  keeps the rule and date centered across every range, and reveals its exact day
  or grouped week/month plus compact token count.
- Shows optional daily and summary token activity from `account/usage/read`
  when the current Codex account supports it.
- Accumulates returned daily token buckets locally, clears them on an explicit
  account change, and supports 7-, 30-, 90-day, one-year, or unlimited local
  retention, storage-size reporting, CSV export, and history clearing. CSV
  exports include both the raw Unix timestamp and a readable ISO 8601 local
  time with its UTC offset.
- Uses native Liquid Glass cards and controls on macOS 26, with the same modern
  chart layout and a system-material fallback on earlier supported macOS.
- Includes an About window and Sparkle-based signed updates. It checks daily,
  supports one-click download/install/relaunch, and can optionally download and
  install future updates automatically.

## How It Works

Changed digits in the menu bar percentage briefly turn red when quota decreases,
hold red for half a second, then smoothly fade back over two seconds; the percent sign keeps its normal color.

CodexMeter launches the locally installed Codex CLI as:

```text
codex app-server --listen stdio://
```

It then communicates with App Server using newline-delimited JSON-RPC messages:

1. Initialize the local App Server connection.
2. Read account metadata with `account/read`.
3. Read ChatGPT rate-limit windows with `account/rateLimits/read`.
4. Read optional banked-reset availability from the same rate-limit response.
5. Optionally read token activity with `account/usage/read` when supported.
6. Record successful quota snapshots and token summaries in account-separated
   local SQLite partitions. ChatGPT accounts use a salted, one-way local key;
   account email and authentication data are never stored.
7. Refresh when `account/updated` or `account/rateLimits/updated` is received.
8. Recover a stale authentication session by restarting only the local App
   Server child process once.
9. Calculate remaining quota, remaining time, consumption pace, and eligible
   history estimates locally.
10. Optionally start the next usage window by creating an ephemeral thread and
    running one minimal turn on the same authenticated App Server connection.
    The app waits for that turn's completion event, records a reservation before
    dispatching, and only reports a started window after a later quota read
    confirms one.

CodexMeter does not scrape ChatGPT pages, read Codex authentication files, or
store access tokens. Authentication and token refresh remain owned by Codex.

Codex App Server is currently an experimental interface intended for local
development and debugging, so future Codex releases may require compatibility
updates. See the official [Codex App Server documentation](https://learn.chatgpt.com/docs/app-server).

## Requirements

- macOS 13 or later.
- Xcode 27 or later when building the current project from source.
- A locally installed Codex CLI.
- A working Codex login.

Install and sign in to Codex CLI if needed:

```bash
npm install -g @openai/codex
codex login
```

CodexMeter currently discovers `codex` in these locations:

```text
~/.local/bin/codex
/opt/homebrew/bin/codex
/usr/local/bin/codex
~/.npm-global/bin/codex
~/.nvm/versions/node/*/bin/codex
```

## Build and Run

### Usage Window Auto-start

Open **Settings → Usage window auto-start** (设置 → 用量窗口自动启动),
select an available model and reasoning effort, then enable automatic start if
desired. Automatic start is off by default. The popover displays a status panel
with a compact automation switch directly after the quota windows and opens
these settings in an independent window. The manual
**Start window now** action is available in the settings status section.
Hiding the popover section leaves the Settings category reachable.

This sends a real model request and may consume quota. It starts an idle usage
window; it does not replenish quota or redeem banked reset credits. A later
quota observation must confirm the window before the app reports success.

### Build from source

Clone the repository:

```bash
git clone https://github.com/N-o-c-t-i-s/CodexMeter.git
cd CodexMeter
open CodexMeter.xcodeproj
```

In Xcode:

1. Select the `CodexMeter` scheme.
2. Select **My Mac** as the destination.
3. Press **Run**.

CodexMeter is a menu-bar-only app, so it does not appear in the Dock. Look for
the quota indicator in the macOS menu bar after launch.

### Tracking the upstream implementation

The native Swift implementation records its reference UWS tag, exact commit,
and source hashes in [Upstream/UsageWindowStarter.lock.json](Upstream/UsageWindowStarter.lock.json).
Maintainers can explicitly prepare a newer tag, inspect its diff, adapt the
Swift implementation, and accept the new pin after verification. See
[Upstream/README.md](Upstream/README.md) for commands. This is a developer
maintenance workflow; application updates still ship as compiled releases.

### Feature snapshot and future CodexMeter upgrades

This fork is maintained at [N-o-c-t-i-s/CodexMeter](https://github.com/N-o-c-t-i-s/CodexMeter).
The annotated tag **`usage-window-autostart-v1.0.0`** records the complete native
feature on CodexMeter 1.7.0, including the inline progress panel, automation
switch, Settings controls, recovery fixes, tests, and upstream-reference tooling.
The app version at this snapshot is **1.7.1-dev (28)**. This feature tag is
separate from the UWS reference tag recorded in `Upstream/`.

Check out the exact source snapshot:

```sh
git clone https://github.com/N-o-c-t-i-s/CodexMeter.git
cd CodexMeter
git switch --detach usage-window-autostart-v1.0.0
```

To keep the feature while bringing newer CodexMeter changes into this fork's
`main`, add the original project as `upstream` once, then merge and verify:

```sh
git switch main
git remote add upstream https://github.com/raycalrui/CodexMeter.git
git fetch upstream --tags
git merge upstream/main
# Resolve any conflicts, then follow the Verification section below.
```

For a clean integration branch starting from a newer upstream revision, the
feature was deliberately saved as one commit, so it can also be reapplied with:

```sh
git fetch origin tag usage-window-autostart-v1.0.0
git fetch upstream
git switch -c integrate/usage-window-auto-start upstream/main
git cherry-pick usage-window-autostart-v1.0.0
```

A Git tag identifies source; fetching it does not install a feature into the
running app or guarantee conflict-free upgrades. The Sparkle feed still follows
the original project's releases, which may not include this fork's feature.
Build and use the updated fork after merging upstream changes. This source tag
does not publish a DMG or a Sparkle update.

## Download and Install

Download `CodexMeter-1.7.0.dmg` from the GitHub Releases page, open it, and drag
CodexMeter into the Applications folder.

The downloadable build uses an ad-hoc signature and is not notarized. On first
launch, macOS may block it. Control-click CodexMeter in Applications, choose
**Open**, and confirm once. A Developer ID certificate and Apple notarization
are planned for a future distribution build.

## Automatic Updates

Starting with version 1.3.0, CodexMeter uses
[Sparkle](https://sparkle-project.org/) to download, verify, replace, and
relaunch the app. Every update archive is signed with a separate EdDSA key, so
this works with the existing ad-hoc app signature and does not require a paid
Apple Developer account. The private EdDSA key remains in the maintainer's
login Keychain and is never stored in the repository or bundled in the app.

Version 1.2.1 does not contain Sparkle, so upgrading from 1.2.1 to 1.3.0 still
requires downloading the DMG manually. Once 1.3.0 is installed, later signed
updates can be installed inside CodexMeter. Because the app is not notarized,
macOS may still show Gatekeeper warnings on a new installation or after an
update; Sparkle does not replace Apple notarization.

## Development

Build from Terminal:

```bash
xcodebuild \
  -project CodexMeter.xcodeproj \
  -scheme CodexMeter \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run the core unit tests:

```bash
swift test
```

If Command Line Tools is selected instead of the full Xcode installation, set
`DEVELOPER_DIR` before running either command.

Pure quota, time, pacing, history, migration, and semantic-version logic lives
under `CodexMeter/Core`. `Package.swift` exposes only that directory to Swift
Package Manager so the core logic can be tested independently of the macOS UI.

### Publishing a Sparkle update

After building the unsigned Release app, re-sign the embedded Sparkle framework
and then the outer app bundle. This order is required because Xcode removes
development headers while embedding the framework:

```bash
Scripts/sign_ad_hoc_release.sh /path/to/CodexMeter.app
```

Create the release DMG from that verified app. Then use Sparkle's bundled
`generate_appcast` utility. The helper below reads the private EdDSA key from
the login Keychain, signs the archive metadata, and updates the repository's
`appcast.xml`:

```bash
Scripts/prepare_sparkle_update.sh \
  v1.7.0 \
  /path/to/CodexMeter-1.7.0.dmg \
  /path/to/Sparkle/bin
```

For a prerelease, pass `beta` as the fourth argument. Upload the exact signed
DMG to the matching GitHub Release, commit and push the generated
`appcast.xml`, then verify its download URL before announcing the release.

See [AGENTS.md](AGENTS.md) for the project architecture, product rules,
verification checklist, and planned developer customization options.

## Privacy and Security

- CodexMeter communicates with a local Codex process over stdio.
- It does not copy or persist Codex access tokens.
- It does not read Codex authentication files directly.
- It does not log account email addresses or raw authentication responses.
- App Server errors use locally authored messages instead of displaying raw
  server errors or system exception details that could contain private data.
- App Server output is read in bounded chunks. A response line over 1 MiB stops
  the child connection and marks the last successful quota as stale; a manual
  or scheduled refresh can reconnect. Diagnostic stderr stays in an 8 KiB
  in-memory tail and is never displayed verbatim.
- In-app updates require Sparkle 2.9.6 or later and retain HTTPS transport and
  EdDSA archive verification.
- It separates ChatGPT account history with a salted SHA-256 key derived
  locally from the account type and normalized email. Neither the email nor
  this internal key is included in CSV exports.
- It does not add its own analytics or tracking.
- Remote notification channels are disabled by default. When enabled, the
  configured service receives the quota-window name and observed remaining
  percentage, but no account email, authentication data, or token history.
  Push keys/tokens and Discord webhook URLs are stored locally in Keychain,
  never in history backups. Legacy plaintext preferences are removed only after
  successful migration; Keychain access failures remain visible and preserve
  the prior credential rather than silently discarding it. An ad-hoc app update
  may require macOS Keychain access approval again.
- Usage history is stored only in
  `~/Library/Application Support/CodexMeter/UsageHistory.sqlite` and can be
  exported or cleared by the user.
- Usage-window auto-start keeps only duplicate-protection records in
  `~/Library/Application Support/CodexMeter/WindowStarter/state.json`: the
  per-account switch and schedule, an attempt identifier, the targeted quota
  window, reservation/send/confirmation timestamps, and a bounded result code.
  It never stores prompts, model output, stderr, tokens, email addresses, or raw
  protocol traffic, and clearing chart history does not clear it.

App Sandbox is currently disabled because CodexMeter must launch the user's
local Codex executable. This should be reviewed deliberately before any future
Mac App Store distribution.

## Settings

The menu-bar **Settings** entry opens one resizable window with General,
Menu Bar & Popover, Notifications, Usage Window Auto-start, History & Backup,
and Developer, followed by About.
Existing preferences are preserved. About/update information opens in the same
settings window; Usage History remains a separate window.

## Remote quota notifications

Open **Settings → Notifications** and enable only the channels you need.
Select five-hour and/or weekly replenishment reminders independently of the
Mac's existing low-quota and over-pace alerts. All remote channels start off.

- **Bark**: enter an HTTPS server address and the device key from the iPhone app;
  an optional HTTPS icon URL is supported.
- **Gotify**: enter your HTTPS server address and application token; choose a
  message priority.
- **Telegram**: create a bot with [@BotFather](https://t.me/BotFather), start a
  chat with it (or add it to a group), then enter its token and the destination
  Chat ID. Use the official [bot setup guide](https://core.telegram.org/bots/tutorial)
  and [getUpdates API](https://core.telegram.org/bots/api#getupdates) to obtain
  your chat ID locally; never publish a URL containing your bot token.
- **Discord**: create a webhook under the destination channel's
  **Integrations → Webhooks** and paste its URL. Anyone with this URL can post
  to that channel, so treat it as a password. See the
  [Discord webhook guide](https://support.discord.com/hc/en-us/articles/228383668-Intro-to-Webhooks).

Use **Send test notification** to check your setup. The status confirms server
acceptance, not whether the phone displayed or you read the message. Temporary
network errors, rate limits, and server failures get at most three attempts;
permanent failures are shown without exposing server responses or secrets.
Changing the account or destination cancels pending old deliveries. HTTPS is
required and redirects are refused to avoid forwarding credentials.

CodexMeter must be running and connected. Notifications describe observed quota
replenishment, not a prediction or an announcement from OpenAI; partial recovery
reports the actual remaining percentage. Initial observations and unused 100%
windows with sliding reset dates do not send reminders. Resets while the app is
closed are not retrospectively replayed. A lost server response can still cause
a duplicate on retry because these services do not share an idempotency protocol.

## Full history backup and restore

Open **Settings → History & Backup → Backup & Restore** to export a `.codexmeterbackup` file.
It includes all retained quota and token history across accounts, database
metadata, and the local identity salt needed to match accounts on another Mac.
It does not contain login credentials, email addresses, or app preferences.
Keep this file private. Previously deleted or retention-pruned records cannot
be recovered. CSV remains a separate readable export format.

Restore replaces all local history after confirmation. CodexMeter validates the
archive version, SHA-256 checksum, database integrity, schema, and row counts,
then saves the existing history in `~/Library/Application Support/CodexMeter/Backups`.
Quit and reopen the app after restoring; history writes pause until then.
Your existing retention preference applies after reopening. An interrupted
restore is rolled back before account activation at the next launch.
Backups larger than 512 MiB are currently unsupported.

## Known Limitations

- Codex App Server is experimental and may change without notice.
- Codex executable discovery uses common stable install locations and installed
  NVM Node versions rather than the interactive shell's `PATH`.
- Notification and launch-at-login behavior must be tested with a signed build.
- Token activity is optional and may be unavailable for API-key, Bedrock, or
  other account types even when quota windows are available.
- Banked-reset availability is account-dependent. Older App Server versions or
  unsupported accounts may omit it; CodexMeter does not treat omission as a
  confirmed zero balance.
- Codex currently provides no stable identifier for API-key and Bedrock
  accounts. CodexMeter therefore cannot restore separate historical profiles
  when switching back and forth between multiple credentials of those types;
  their anonymous history partition is reset on an explicit account change.
- Usage-window auto-start sends a real minimal model request. It consumes a
  small amount of quota, it does not add quota, and it does not end a window
  that is already running.
- Only the standard `codex` bucket's 300-minute window is targeted. A missing
  standard bucket, a conflicting duplicate window, unknown backend fields, an
  API-key or Bedrock account, and any ambiguity in the idle heuristic all pause
  the feature instead of guessing.
- The idle heuristic uses an empirical 45-second tolerance and a bounded
  sliding-reset comparison. It is not a backend guarantee; Codex started
  reporting a hypothetical window for an idle account and may change that
  behavior.
- A send whose outcome cannot be observed keeps its duplicate protection. It is
  cleared from the settings window, which does not resend.
- Only one usage-window auto-starter should be enabled on a Mac. Another
  launcher that also starts Codex windows is not coordinated with. Running two
  CodexMeter copies is serialized by a file lock: only one can hold the
  duplicate-protection document, so the second reports "another copy is
  handling it" instead of sending.
- The start turn runs in an app-owned empty directory, but Codex still applies
  the user's `$CODEX_HOME/AGENTS.md` and any configured MCP servers, hooks, and
  tools. The empty directory only excludes project files, so this is not a
  minimal-context request. The prompt is one line, the sandbox is read-only, and
  approvals are disabled, so the turn cannot modify files or prompt for
  permission.
- The downloadable DMG is ad-hoc signed, not notarized, and not prepared for
  the Mac App Store, so first launch may require Control-clicking the app and
  choosing **Open**.

## Contributing

Issues and pull requests are welcome.

Before submitting a change:

```bash
swift test
git diff --check
```

For menu bar or popover changes, also launch exactly one signed app instance and
perform a UI smoke test.

## License

CodexMeter is available under the [MIT License](LICENSE).

## Acknowledgements

The usage-window start heuristics — the hypothetical-window tolerance, the
sliding-reset idle check, and the post-send confirmation delay — are derived
from [Usage Window Starter](https://github.com/foksa/usage-window-starter) by
Djordje Radakovic, which is MIT licensed. The implementation here is native
Swift written against Codex App Server; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Disclaimer

Codex and OpenAI are trademarks of OpenAI. This project is provided as an
independent utility and may stop working when upstream experimental interfaces
change.
