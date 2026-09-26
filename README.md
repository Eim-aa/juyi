# 句译 Juyi

<img src="macos/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" width="80" height="80" alt="句译图标" />

**读懂这一句，继续读下去。**

在 Mac 上选中英文，连按两次 **Option（⌥⌥）**，中文译文就在旁边。不必切换窗口，也不用来回复制粘贴。

**[下载 macOS 测试版](https://github.com/Eim-aa/juyi/releases/download/v0.4.0-preview.15/Juyi-0.4.0-build15-universal.dmg)** · [更新说明](https://github.com/Eim-aa/juyi/releases/tag/v0.4.0-preview.15) · [English](README_EN.md)

macOS 15+ · 英语 → 简体中文 · 免费开源 · MIT

![句译实际操作：在预览中选中 PDF 英文，中文译文出现在浮窗中](docs/media/selection-demo.gif)

[观看清晰版实录](docs/media/selection-demo.mp4) · 这段录像来自 build 10，展示基本操作，不代表当前版本的速度或验收结果。

## 少一点打断，多一点阅读

- **译文就在旁边**：读网页、文档和文字型 PDF 时，在支持的 App 中划词翻译。
- **默认本地翻译**：使用 Apple 翻译，在 Mac 上处理正文；语言包准备好后可离线使用。
- **安装就能开始**：本地模式无需 API 密钥、Hammerspoon、Python 或 Homebrew。

## 三步开始

1. **下载安装**：打开 DMG，把「句译」拖入「应用程序」（`/Applications/句译.app`），然后打开。下载无需登录 GitHub。
2. **完成设置**：按提示为句译开启「辅助功能」权限；首次使用可能需要联网下载 Apple 中英语言包。
3. **选中 → ⌥⌥ → 看译文**：在文本编辑、预览等支持的 App 中选中英文，再快速连按两次 Option。

是**连按两次同一个 Option 键**，不是同时按住两个 Option。关闭主窗口后仍可翻译；退出再打开时，点击「恢复翻译」。

<details>
<summary>看看句译的界面</summary>

<img src="docs/media/home-ready.jpg" width="440" alt="句译首页：本地 Apple 翻译已就绪" />

实机截图，具体界面以下载版本为准。

</details>

## 下载前了解这几点

- **当前是公开测试版**：build 15 已签名并通过 Apple 公证，不是稳定版，也不是 App Store 版本。安装包包含 Apple Silicon 和 Intel 两种架构；[实测范围与待验收项](docs/RELEASE_0.4.0_BUILD15.md)仍在逐步补齐。
- **不是所有 App 都能取词**：兼容性取决于 App 提供的选区接口。不支持扫描 PDF、图片文字、安全输入框或受保护内容；没有 OCR。
- **WPS PDF 通常比预览慢**：兼容取词需要额外复制校验，可能临时使用剪贴板并尽力恢复。剪贴板管理器可能保留原文，敏感内容请避免这条路径。

## 本地与云端

推荐直接用 **本地 · Apple**：不需要密钥，句译不会将翻译正文发送到云端，也不会在本地失败后自动改用云端。

**云端目前仅支持火山翻译**，需要另装后台组件并自行配置火山 AK/SK。开启后，选中文字会发送至火山；密钥保存在 macOS 钥匙串。不支持任意厂商的密钥或自定义 API。详见[配置说明](docs/MENU_BAR_APP.md#翻译方式)。

## 帮句译变得更好

遇到问题或有想法？[提交 Issue](https://github.com/Eim-aa/juyi/issues)。请附上 macOS 版本、句译版本、使用的 App 和复现步骤；不要上传密钥、私人选文或剪贴板内容。欢迎提交 PR。

[使用与排查](docs/MENU_BAR_APP.md) · [源码安装 / Agent 指引](AGENTS.md) · [构建与发布](docs/RELEASE_BASELINE.md) · [MIT 许可](LICENSE)
