# AGENTS.md

Instructions for an AI coding agent (Claude Code, OpenHands, Codex, etc.) asked
to install or deploy **juyi** (句译) on the user's behalf.

This is a macOS-only, English→Chinese, selection-translation tool: select English
text in a compatible app, double-tap the Option key, and a popup shows Chinese. It runs a
local FastAPI service on `127.0.0.1:54321` and a Hammerspoon Lua client.

Read this whole file before acting. Most steps you can run yourself; **two steps
require the human** and are marked `HUMAN STEP`. Do not try to automate those.

## Prerequisites (verify, don't assume)

- macOS (the tool is macOS-only; bail out otherwise). macOS 15+ enables the
  default offline engine; older macOS works cloud-only with Volcengine keys.
- A shell you can run commands in.
- Homebrew and Python >= 3.10. The installer checks these and prints a fix hint
  if missing; install Homebrew first if it is absent.

## Step 1 — Install the service (you can do this)

Run the one-line bootstrap (clones to `~/.local/share/argos-translator` and runs
the installer):

```bash
curl -fsSL https://raw.githubusercontent.com/Eim-aa/juyi/main/scripts/bootstrap.sh | bash
```

The installer creates a venv, installs `requirements.txt` (FastAPI/uvicorn only),
compiles the Apple on-device translation helper on macOS 15+, loads a
LaunchAgent on `127.0.0.1:54321`, generates an owner-only local API token, and
wires the Hammerspoon module into a managed block in `~/.hammerspoon/init.lua`.
The app itself does not bundle a model; macOS may download the en-zh language
pack on first use.

## Step 2 — Install Hammerspoon (you can do this)

```bash
brew install --cask hammerspoon
open -a Hammerspoon
```

## Step 3 — Grant Accessibility permission `HUMAN STEP`

Hammerspoon needs Accessibility permission to read the selected text and send the
hotkey. This is gated by macOS TCC and **cannot be granted by a script or agent**.

Stop and ask the human to do this:

> Open System Settings → Privacy & Security → Accessibility, and enable the
> toggle for **Hammerspoon**. Then reload the Hammerspoon config.

Do not attempt to edit the TCC database or otherwise bypass this.

## Step 4 — Choose the engine

Two modes (see the "Local vs Cloud" section in README for the trade-off):

- **Apple on-device (default and recommended, `apple`, macOS 15+)** — offline,
  no keys, and text stays on the machine. The helper is compiled automatically
  when macOS 15+ and `swiftc` are present (`bin/apple-translation-helper`). The
  first use may require the human to confirm the system language-pack download
  dialog (`bin/apple-translation-helper --prepare` triggers it manually). If the
  user only wants this, you are done after Step 3. Verify (Step 6).
- **Cloud (`ENGINE=volc`, optional)** — sends selected text to the Volcengine
  API. Use it only after the human explicitly chooses it and evaluates it on
  their own content. Continue to Step 5.

## Step 5 — Configure the Volcengine cloud engine (only if chosen)

### 5a. Get credentials `HUMAN STEP`

The human must, in the [Volcengine console](https://console.volcengine.com/):
enable "Machine Translation", grant their (sub-)user `TranslateFullAccess`, and
create an Access Key / Secret Key pair. Account signup and key creation require a
real account and cannot be automated. **Do not ask the human to paste the Secret
Key into chat or a shell command.**

### 5b. Save the credential in Juyi `HUMAN STEP`

Ask the human to open `/Applications/句译.app`, select **火山云端**, and enter the
AK/SK in the native secure form. Juyi validates the candidate before replacing
the existing credential and stores it in macOS Keychain under the service
`io.github.Eim-aa.juyi.volc`. The Secret Key must not be written to source,
shell history, logs, or the repository.

Legacy installations may still contain AK/SK values in
`~/.config/argos-translator/volc.env`. On first native-app launch they are
migrated to Keychain and removed from the file; `ENGINE=volc` may remain because
it is not a secret. Do not create a new plaintext credential file.

## Step 6 — Verify (you can do this)

```bash
# Service is up:
curl -s http://127.0.0.1:54321/health
# Authenticated translation and edge-case checks (reads the token without
# placing it in shell history or a command-line argument):
JUYI_INSTALL_ROOT="${DEST:-$HOME/.local/share/argos-translator}"
"$JUYI_INSTALL_ROOT/venv/bin/python" "$JUYI_INSTALL_ROOT/scripts/smoke.py"
```

A non-empty Chinese `result` means the service works. The end-to-end hotkey
(select text → double-tap Option → popup) can only be confirmed by the human,
since it depends on the Accessibility grant from Step 3. Tell them to try it.

Full diagnostics: `~/.local/share/argos-translator/scripts/test.sh`.

## Security rules (do not violate)

- Volcengine credentials live in **macOS Keychain**, not source files or the
  repository. A legacy `volc.env` may be read only for migration; never create
  a new plaintext key file.
- The local API token lives at
  `~/.config/argos-translator/auth-token` (`chmod 600`). Never print or commit it.
- Never `git add`/`commit`/`push` a credential. If you ever see a key in a diff,
  stop and remove it.
- Do not echo the user's secret key back in full in your messages.

## If this is a fork

If the user forked the repo under a different account, replace `Eim-aa` with their
GitHub username in URLs and in the LaunchAgent label
(`io.github.<username>.argos-translator`) before running the steps.
