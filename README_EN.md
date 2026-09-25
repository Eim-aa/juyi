# juyi 句译

**Understand the sentence. Keep reading.**

Select English in a supported Mac app, double-tap **Option (⌥⌥)**, and read Simplified Chinese beside the selection.

[Download the Mac DMG · build 12](https://github.com/Eim-aa/juyi/releases/download/v0.4.0-preview.12/Juyi-0.4.0-build12-universal.dmg) · [Release notes and checksums](https://github.com/Eim-aa/juyi/releases/tag/v0.4.0-preview.12) · [中文](README.md)

This is a signed, notarized **public preview, not a stable release**. No GitHub account is needed to download. Use the DMG, not the repository ZIP or unsigned CI artifacts.

![Actual PDF selection and translated popup](https://raw.githubusercontent.com/Eim-aa/juyi/v0.4.0-preview.12/docs/media/selection-demo.gif)

This build 10 recording illustrates the workflow, not acceptance of the latest build or a performance guarantee. [Watch the MP4](https://github.com/Eim-aa/juyi/blob/v0.4.0-preview.12/docs/media/selection-demo.mp4).

## Three steps

1. Use **macOS 15+**. Open the DMG, drag **句译.app** to **Applications**, then open it from Applications.
2. Enable double Option, grant Accessibility permission to **Juyi**, and approve Apple's English–Simplified Chinese language resources if prompted.
3. Select English in TextEdit or a supported text-PDF reader and tap Option twice in succession. Do not hold both Option keys together.

**Local translation needs only Juyi: no Hammerspoon, Python, Homebrew, or API key.** Existing development components use the safe handoff. Quit an older version normally before updating. Do not bypass Gatekeeper or alter the system permission database.

Closing the main window keeps Juyi running; pausing stops translation; reopening after quitting requires Resume translation. System permission, language downloads, and the real global gesture must be completed by the person using the Mac.

## Scope and privacy

- **English → Simplified Chinese only.** Selection support depends on each app's interfaces. Not all apps or PDFs are supported; no OCR, scanned pages, secure fields, or protected content.
- **Local · Apple (default):** translation content stays on the Mac. Initial language resources may need a network connection. Local failure never automatically sends text to the cloud.
- **WPS PDF:** a compatibility path may temporarily copy text and attempt to restore the clipboard. Clipboard managers can retain text; avoid this path for sensitive content.
- **Cloud · Volcengine (optional):** currently only Volcengine, not arbitrary APIs. It requires separately installed cloud components and credentials entered by the user in the newer app's secure form. Only explicit cloud selection sends text to Volcengine. Credentials are stored in macOS Keychain.

**Never give keys to an agent or place them in chat, shell history, source code, or plaintext configuration files.** Existing legacy plaintext credentials should only be handled by the newer app's migration flow. Local translation needs no key.

## Verification status

The package passed Universal 2, signature, notarization, Gatekeeper, and anonymous-download checks. A user confirmed build 12's real TextEdit selection → double Option → translated popup on the existing development Mac. Including both architectures is not proof of Intel hardware testing.

Clean-account first permission/language setup, this build's PDF regression, macOS 15, and Intel hardware still need acceptance. See the [version-specific release notes](https://github.com/Eim-aa/juyi/releases/tag/v0.4.0-preview.12). Distribution is through GitHub, not the App Store.

## Source and feedback

The early scripts in the default branch are not the installer for this native preview. Use the [release-tag source](https://github.com/Eim-aa/juyi/tree/v0.4.0-preview.12); later development is in the [existing PR](https://github.com/Eim-aa/juyi/pull/1). Read the [version-specific instructions](https://github.com/Eim-aa/juyi/blob/v0.4.0-preview.12/AGENTS.md) before source builds or optional cloud setup. Do not mix old-branch instructions with the preview.

[Report issues](https://github.com/Eim-aa/juyi/issues) with the app/system/reader versions and non-sensitive reproduction steps. Never include keys or complete private documents.

MIT; see [LICENSE](LICENSE).
