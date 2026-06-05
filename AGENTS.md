# AGENTS.md

Instructions for an AI coding agent (Claude Code, OpenHands, Codex, etc.) asked
to install or deploy **juyi** (句译) on the user's behalf.

This is a macOS-only, English→Chinese, selection-translation tool: select English
text in any app, double-tap the Option key, a popup shows the Chinese. It runs a
local FastAPI service on `127.0.0.1:54321` and a Hammerspoon Lua client.

Read this whole file before acting. Most steps you can run yourself; **two steps
require the human** and are marked `HUMAN STEP`. Do not try to automate those.

## Prerequisites (verify, don't assume)

- macOS (the tool is macOS-only; bail out otherwise).
- A shell you can run commands in.
- Homebrew and Python >= 3.10. The installer checks these and prints a fix hint
  if missing; install Homebrew first if it is absent.

## Step 1 — Install the service (you can do this)

Run the one-line bootstrap (clones to `~/.local/share/argos-translator` and runs
the installer):

```bash
curl -fsSL https://raw.githubusercontent.com/Eim-aa/juyi/main/scripts/bootstrap.sh | bash
```

The installer creates a venv, installs `requirements.txt`, downloads the
`translate-en_zh` offline model (~150 MB, the only network call), loads a
LaunchAgent on `127.0.0.1:54321`, and wires the Hammerspoon module into
`~/.hammerspoon/init.lua`.

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

- **Offline (default, `ENGINE=argos`)** — works now, no keys, text stays on the
  machine. If the user only wants this, you are done after Step 3. Verify (Step 6).
- **Cloud (`ENGINE=volc`, recommended for long/complex sentences)** — higher
  accuracy via the Volcengine API. Continue to Step 5.

## Step 5 — Configure the Volcengine cloud engine (only if chosen)

### 5a. Get credentials `HUMAN STEP`

The human must, in the [Volcengine console](https://console.volcengine.com/):
enable "Machine Translation", grant their (sub-)user `TranslateFullAccess`, and
create an Access Key / Secret Key pair. Account signup and key creation require a
real account and cannot be automated. Ask the human to paste you the AK and SK.

### 5b. Write the key file (you can do this)

Put the credentials **only** in this local, gitignored file — never in source,
never in the repo:

```bash
mkdir -p ~/.config/argos-translator
cat > ~/.config/argos-translator/volc.env <<EOF
VOLC_ACCESS_KEY=<AccessKeyID the human gave you>
VOLC_SECRET_KEY=<SecretAccessKey the human gave you>
ENGINE=volc
EOF
chmod 600 ~/.config/argos-translator/volc.env
```

Then restart the service so it picks up the new engine:

```bash
launchctl kickstart -k gui/$(id -u)/io.github.Eim-aa.argos-translator
```

## Step 6 — Verify (you can do this)

```bash
# Service is up:
curl -s http://127.0.0.1:54321/health
# Real translation round-trip:
curl -s -X POST http://127.0.0.1:54321/translate \
  -H 'Content-Type: application/json' \
  -d '{"text":"The central bank held interest rates steady, citing easing inflation."}'
```

A non-empty Chinese `result` means the service works. The end-to-end hotkey
(select text → double-tap Option → popup) can only be confirmed by the human,
since it depends on the Accessibility grant from Step 3. Tell them to try it.

Full diagnostics: `~/.local/share/argos-translator/scripts/test.sh`.

## Security rules (do not violate)

- API keys live **only** in `~/.config/argos-translator/volc.env` (gitignored,
  `chmod 600`, outside the repo). Never hardcode a key in any source file.
- Never `git add`/`commit`/`push` a credential. If you ever see a key in a diff,
  stop and remove it.
- Do not echo the user's secret key back in full in your messages.

## If this is a fork

If the user forked the repo under a different account, replace `Eim-aa` with their
GitHub username in URLs and in the LaunchAgent label
(`io.github.<username>.argos-translator`) before running the steps.
