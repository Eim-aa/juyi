# 句译 juyi

**读懂这一句，继续读下去。**

在支持的 Mac App 中选中英文，连按两次 **Option（⌥⌥）**，在选区旁查看中文译文。

[直接下载 Mac 安装包 · build 12](https://github.com/Eim-aa/juyi/releases/download/v0.4.0-preview.12/Juyi-0.4.0-build12-universal.dmg) · [发布说明与校验文件](https://github.com/Eim-aa/juyi/releases/tag/v0.4.0-preview.12) · [English](README_EN.md)

当前是已签名、公证的**公开测试版，不是稳定版**。下载不需要 GitHub 账户。请下载 DMG，不是仓库 ZIP 或 CI 构建产物。

![句译真实 PDF 操作演示](https://raw.githubusercontent.com/Eim-aa/juyi/v0.4.0-preview.12/docs/media/selection-demo.gif)

这段实录来自 build 10，用于展示操作，不是最新版本验收或性能保证。[观看 MP4](https://github.com/Eim-aa/juyi/blob/v0.4.0-preview.12/docs/media/selection-demo.mp4)。

## 三步开始

1. 需要 **macOS 15+**。打开 DMG，把 **句译.app** 拖到 **Applications**，再从“应用程序”打开。
2. 点击启用双 Option，按系统提示为**句译**授予辅助功能权限；需要时确认 Apple 中英语言资源下载。
3. 在文本编辑或支持的文字型 PDF 阅读器中选中英文，连续按两次 Option，查看译文。不是同时按住两个 Option 键。

**本地翻译只需安装句译，不需要 Hammerspoon、Python、Homebrew 或 API 密钥。** 已有早期开发组件时，App 会通过既有协议安全交接。更新前请正常退出旧版。不要绕过 Gatekeeper 或修改系统权限数据库。

关闭主窗口后仍在菜单栏运行；暂停会停止翻译；退出再打开后点击“恢复翻译”。系统授权、语言包确认和实际全局快捷键须由本人完成。

## 支持范围与隐私

- 当前仅 **英语 → 简体中文**。其他 App 和文字型 PDF 能否读取，取决于它们的选区接口；不支持所有 App、OCR、扫描件、安全输入框或受保护内容。
- **本地 · Apple（默认）**：翻译正文在本机处理，首次语言资源可能需要联网；本地失败不会自动上传云端。
- **WPS PDF**：兼容取词可能临时复制并尽力恢复剪贴板。剪贴板管理器可能保留正文，敏感内容请避免此路径。
- **云端 · 火山（可选）**：目前仅支持火山，不支持任意 API。需要另行安装云端后台并由本人在新版 App 的安全表单输入 AK/SK；只有主动选择后才向火山发送选中文字。密钥保存在 macOS 钥匙串。

**不要把密钥交给 Agent，也不要贴进聊天、终端历史、源码或明文配置文件。** 旧版明文凭据只能由新版的既有迁移流程处理；本地翻译不需要任何密钥。

## 验证状态

发布包已通过双架构构建、签名、公证、Gatekeeper 和匿名下载校验；本机 build 12 的文本编辑真实双 Option 翻译已由用户确认。Universal 2 包含 Apple Silicon 与 Intel，但不代表两类硬件均已实测。

干净账户首次授权与语言包、此版本 PDF、macOS 15 与 Intel 真机仍有待验证。具体状态以[该版本发布说明](https://github.com/Eim-aa/juyi/releases/tag/v0.4.0-preview.12)为准。目前通过 GitHub 分发，未上架 App Store。

## 源码与反馈

默认分支中的早期脚本不是上述原生测试版的安装入口。新版源码在[发布标签](https://github.com/Eim-aa/juyi/tree/v0.4.0-preview.12)，后续改动见[现有开发 PR](https://github.com/Eim-aa/juyi/pull/1)。源码开发或可选云端安装请先阅读[对应版本的说明](https://github.com/Eim-aa/juyi/blob/v0.4.0-preview.12/AGENTS.md)，不要混用旧分支安装步骤。

注意：该固定标签的说明中，指向 `main/scripts/bootstrap.sh` 的一行安装命令已过时，必须跳过。源码安装须先在新的目录中检出 `v0.4.0-preview.12`（提交 `5e0a92f`），再从这个 checkout 运行 `scripts/install.sh`；仅把 bootstrap 下载 URL 改为 tag，不能保证其内部克隆也锁定该版本。已有工作目录请勿覆盖。

[提交问题](https://github.com/Eim-aa/juyi/issues)时请附版本、macOS、阅读器和不含隐私的复现步骤；不要附密钥或完整私人文档。

MIT，见 [LICENSE](LICENSE)。
