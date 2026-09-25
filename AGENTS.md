# Juyi installation guidance

Use the signed, notarized native preview from [GitHub Releases](https://github.com/Eim-aa/juyi/releases/tag/v0.4.0-preview.12) for normal local translation. The early scripts on this default branch are not the installer for that app.

## Native installation

1. Verify macOS 15 or newer.
2. Download the version-specific DMG without a GitHub login, verify its published checksum and signature/notarization, and install Juyi in Applications.
3. The user must grant Accessibility permission to **Juyi**, approve any Apple language-resource download, and physically test selecting English in another app and double-tapping Option. Do not automate or bypass these human steps.
4. Record the exact app build and test environment. Do not call an existing configured Mac a clean-install test or treat an engine self-test as end-to-end acceptance.

Apple local translation needs no Hammerspoon, Python, Homebrew, background service, or API key on a clean installation. Existing development components retain the established safe owner handoff. Do not remove user configuration or relax fail-closed checks to manufacture a clean environment.

## Source and optional cloud setup

Before source installation, use the [instructions at the release tag](https://github.com/Eim-aa/juyi/blob/v0.4.0-preview.12/AGENTS.md), not the old default-branch bootstrap. The native release source is at that tag; the existing development PR is https://github.com/Eim-aa/juyi/pull/1.

Cloud is optional, currently Volcengine only, and requires separate background components. Do not enable it or upload text unless the user explicitly chooses it.

The user creates and enters cloud credentials directly in the newer app's secure configuration form. The app stores them in macOS Keychain. **Never ask the user to send AK/SK, passwords, or other secrets in chat. Never create plaintext credential files or put secrets in source, command arguments, shell history, or Git.** Do not run the old plaintext-key setup from earlier instructions. Existing credentials may only be handled by the newer app's existing migration flow.

Do not read, execute, modify, stage, or commit `scripts/start_service.command`. Do not inspect the repository `tmp/` directory. Preserve unrelated user edits and use explicit paths for staging. Never modify TCC or bypass Gatekeeper. A preview is not a stable release or an App Store approval.
