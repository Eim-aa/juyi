# AGENTS.md

Instructions for an AI coding agent (Claude Code, OpenHands, Codex, etc.) asked
to install or deploy **juyi** (句译) on the user's behalf.

This is a macOS-only, English→Chinese, selection-translation tool: select English
text in a compatible app, double-tap the Option key, and a popup shows Chinese.
The native app does everything itself: the Option monitor, the Accessibility
selection read, translation (Apple on-device by default, or the optional
Volcengine cloud engine), the popup and read-aloud. There is no Python service,
LaunchAgent service, Hammerspoon module or helper CLI to install.

Read this whole file before acting. Permissions, Apple language downloads,
real global shortcut acceptance, and cloud account/credential entry require the
human. Do not automate or bypass those steps.

## Step 1 — Download and install the app

Download the signed, notarized DMG from
[GitHub Releases](https://github.com/Eim-aa/juyi/releases), drag 句译 into
Applications (`/Applications/句译.app`), and open it. The releases are previews,
not stable releases; read the release record of the build you install. No
Homebrew, Python, background service or source build is required. Never bypass
Gatekeeper and never remove the quarantine attribute.

Only if the human explicitly asks for a source build: `scripts/install_macos_app.sh`
builds, ad-hoc signs, validates and installs the app to `/Applications/句译.app`
(macOS 15+ and Xcode required). A local build is not notarized.

Record the exact build and environment. An already-configured Mac is not a
clean installation test; an engine self-test does not establish end-to-end
acceptance.

## Step 2 — Grant Accessibility `HUMAN STEP`

In Juyi's setup step 1, choose to enable native double Option. Accessibility
permission lets the app monitor Option and read the selection; it is gated by
macOS TCC and **cannot be granted by a script or agent**. Stop and ask the human:

> Open System Settings → Privacy & Security → Accessibility, and enable the
> toggle for **句译**. Return to Juyi; it rechecks the permission.

Do not attempt to edit the TCC database or otherwise bypass this. For the
default Apple engine the human may also need to confirm the system download of
the English–Chinese language pack.

In setup step 2, the human must switch to another app, select English text, and
double-tap Option. Juyi intentionally does not translate selections from its own
window. After the popup appears, they confirm it in Juyi.

If Juyi shows **检测到早期组件** (early components detected), the Mac still has
parts of a pre-native source installation (Hammerspoon module, background
service LaunchAgent, `~/.config/argos-translator`). Juyi keeps double-Option
disabled until the human clicks **移除早期组件**; it removes only items Juyi
created. Let the human click it; do not delete those files yourself.

## Step 3 — Optional: Volcengine cloud key `HUMAN STEP`

Apple on-device translation is the default and recommended engine: offline,
no keys, and text stays on the machine. Use cloud only after the human
explicitly chooses it and understands that the selected English text is sent to
Volcengine. There is no fallback in either direction.

The human must, in the [Volcengine console](https://console.volcengine.com/),
enable Machine Translation, grant their (sub-)user `TranslateFullAccess`, and
create an Access Key / Secret Key pair. Account signup and key creation require a
real account and cannot be automated. **Do not ask the human to paste the Secret
Key into chat or a shell command.**

Ask the human to open Juyi → 翻译方式 → 使用云端翻译…, enter the AK/SK in the
native secure form and click 保存并验证. Juyi validates the candidate with one
fixed English sentence before replacing any existing credential and stores it in
macOS Keychain under the service `io.github.Eim-aa.juyi.volc`.

In-app cloud setup applies to build 17 and later. The published build 16 cloud
path still depends on the removed background service, which this repository no
longer contains; on build 16 use the Apple engine.

## Verify

Only the human can confirm end-to-end acceptance: in another app, select text →
double-tap Option → native popup. Juyi's 诊断与帮助 → 测试翻译引擎 only proves
the selected engine can translate a fixed sentence.

## Uninstall

`scripts/uninstall.sh` quits Juyi, removes its login item, asks before deleting
the Volcengine Keychain item, removes early components (legacy LaunchAgent,
Juyi-created Hammerspoon symlink and managed block, `~/.config/argos-translator`)
and moves the app to the Trash. Run it only when the human asks.

## Security rules (do not violate)

- Do not read, execute, modify, stage, or commit `scripts/start_service.command`.
  Do not inspect the repository `tmp/` directory. Preserve unrelated user edits.
- Volcengine credentials live in **macOS Keychain** only, never in source files,
  the repository, UserDefaults, logs or any plaintext file. Never create a
  plaintext key file.
- Never `git add`/`commit`/`push` a credential. If you ever see a key in a diff,
  stop and remove it.
- Do not echo the user's secret key back in full in your messages.

## If this is a fork

If the user forked the repo under a different account, replace `Eim-aa` with
their GitHub username in the release URLs above.
