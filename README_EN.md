# Juyi 句译

<img src="macos/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" width="80" height="80" alt="Juyi icon" />

**Understand the sentence. Keep reading.**

Select English on your Mac, double-tap **Option (⌥⌥)**, and read Simplified Chinese beside your selection. No window switching or manual copy-paste.

**[Download for macOS — Preview](https://github.com/Eim-aa/juyi/releases/download/v0.4.0-preview.15/Juyi-0.4.0-build15-universal.dmg)** · [Release notes](https://github.com/Eim-aa/juyi/releases/tag/v0.4.0-preview.15) · [中文](README.md)

macOS 15+ · English → Simplified Chinese · Free & open source · MIT

![Actual PDF selection and translated popup in Preview](docs/media/selection-demo.gif)

[Watch the full-resolution clip](docs/media/selection-demo.mp4) · Recorded with build 10 to show the workflow, not current-version performance or acceptance results.

## Less switching. More reading.

- **Translation beside the text** — read webpages, documents and text-based PDFs in supported apps.
- **Local by default** — Apple Translation processes text on your Mac. Once the language pack is ready, it works offline.
- **A standalone Mac app** — local mode needs no API key, Hammerspoon, Python or Homebrew.

## Get started in three steps

1. **Download and install.** Open the DMG, drag Juyi to Applications (`/Applications/句译.app`), then open it. No GitHub login needed.
2. **Finish setup.** Grant Juyi Accessibility permission when prompted. First use may need an internet connection to download Apple's English–Chinese language pack.
3. **Select → ⌥⌥ → read.** Select English in a supported app, such as TextEdit or Preview, and tap Option twice in quick succession.

Tap **the same Option key twice**, not both Option keys at once. Closing the main window keeps translation running. After quitting and reopening, click **Resume translation (恢复翻译)**. The app interface is currently in Chinese.

<details>
<summary>See the interface</summary>

<img src="docs/media/home-ready.jpg" width="440" alt="Juyi's home screen, ready for local Apple translation" />

An actual app screenshot; the downloaded version may look different.

</details>

## Before you download

- **A public preview, not a stable release.** Build 15 is signed and Apple-notarized, not an App Store release. The Universal 2 package includes Apple Silicon and Intel binaries; [device coverage and acceptance checks](docs/RELEASE_0.4.0_BUILD15.md) are still being completed.
- **Not every app exposes its selection.** Compatibility depends on the source app. Scanned PDFs, text in images, secure fields and protected content are unsupported. No OCR.
- **WPS PDFs usually take longer than Preview.** The compatibility path performs extra copy checks, temporarily uses the clipboard and attempts to restore it. Clipboard managers may retain the source text; avoid this path for sensitive content.

## Local and cloud translation

Start with **Local · Apple**: no key required. Juyi does not send translation text to the cloud or automatically switch to cloud when local translation fails.

**Cloud currently supports Volcengine only.** It requires separately installed backend components and your own Volcengine AK/SK. When enabled, selected text is sent to Volcengine; credentials are stored in macOS Keychain. Other providers' keys and custom API endpoints are not supported. See the [configuration guide](docs/MENU_BAR_APP.md#翻译方式) (Chinese).

## Help improve Juyi

Found a problem or have an idea? [Open an issue](https://github.com/Eim-aa/juyi/issues) with your macOS version, Juyi version, source app and reproduction steps. Do not include credentials, private selected text or clipboard contents. Pull requests are welcome.

[Usage & troubleshooting](docs/MENU_BAR_APP.md) · [Source installation / Agent guide](AGENTS.md) · [Build & release](docs/RELEASE_BASELINE.md) · [MIT license](LICENSE)
