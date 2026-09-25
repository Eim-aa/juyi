# 句译 0.4.0 · build 11（公开测试版）

无需 GitHub 账户即可下载。安装包已完成 Developer ID 签名、Apple 公证、票据附加及 Gatekeeper 检查，对应源码的 GitHub CI 全部通过。**这是公开测试版，不是稳定版**：干净环境首次安装和不同硬件仍待验证。

## 下载并开始使用

**[下载句译 Mac 安装包（约 4 MB）](https://github.com/Eim-aa/juyi/releases/download/v0.4.0-preview.11/Juyi-0.4.0-build11-universal.dmg)**

适用于 macOS 15 或更新系统，包含 Apple Silicon 和 Intel 架构。无需登录 GitHub、开发者账户、终端命令或 API 密钥。

1. 打开 DMG，把 **句译.app** 拖入 **Applications**，再从“应用程序”打开句译。更新前请正常退出旧版。
2. **这个测试版仍需 Hammerspoon 兼容组件**。如果尚未安装，从 [Hammerspoon 官网](https://www.hammerspoon.org/) 下载并拖入“应用程序”，打开一次，再回到句译按引导继续。不要使用源码安装命令，也无需自行编辑配置。
3. 按句译提示为 **句译** 开启辅助功能权限，保留“本地翻译 · Apple”，按需确认系统语言包下载。
4. 在文本编辑或文字型 PDF 里选中英文，连续按两次 Option，查看中文浮窗。

DMG 内附可离线打开的“安装与第一次翻译”说明。公证不保证没有功能问题；若 macOS 阻止打开，请报告提示，不要关闭系统安全保护。遇到问题请说明系统版本、阅读器及失败步骤，不要上传密码或私人文档。

## 用户可用的变化

- 原生首页、设置和翻译浮窗重新整理，明确区分准备、就绪、暂停和需要处理。
- 本地翻译由 Apple 提供；云端目前仅支持火山，明确密钥限制和文字上传范围。
- 文字型 PDF 的行尾断词在翻译前进行保守整理，兼容预览与 WPS 提取差异；用户已确认本机问题修复。
- 新增真实 PDF 翻译演示，保留原始等待过程，不使用示意图冒充实录。
- DMG 内提供应用程序快捷入口和可离线阅读的安装、权限及首次翻译指引。

## 安装前提与限制

macOS 15+，Universal 2。当前预览仍需 Hammerspoon、句译辅助功能授权及系统中英语言资源。预编译 Apple 本地路径无需 Python；火山云端后台仍为高级源码安装。仅英语 → 简体中文；没有 OCR，不保证任意 App、扫描 PDF 或跨栏排版兼容。WPS PDF 可能临时复制并尽力恢复剪贴板。

## 发布验收

- [x] 本机用户确认 PDF、长段落、暂停恢复及 PDF 断词修复可用（不同构建的证据见相关文档）。
- [x] build 11 App 的 Universal 2、最低系统、Developer ID、时间戳与 Hardened Runtime 检查。
- [x] 本地回归检查及现有选区/浮窗测试通过。
- [x] 对应源码提交 `8c7217c` 的两轮 GitHub CI 全部通过。
- [x] 最终 DMG 公证 Accepted、staple 及 Gatekeeper 检查。
- [ ] 干净账户首次安装、辅助功能、首次语言包、双 Option、退出重开和升级回退。
- [ ] macOS 15 / Intel 实际硬件兼容性验证（构建包含架构不代表实测）。

当前工作机为 Apple Silicon、macOS 26.5.1。不会重置用户现有 TCC 或删除语言包来冒充干净环境。App Store 版本另见 [可行性评估](https://github.com/Eim-aa/juyi/blob/8c7217c258fb9f48d3018d571920921b23363d1a/docs/APP_STORE_FEASIBILITY.md)。

## 公证证据

2026-09-25，Apple 公证提交 `81e86788-4d2b-47a4-95c2-ba4baabd39e9` 返回 Accepted。`stapler validate` 成功；DMG 的 Gatekeeper 检查返回 `accepted`、`source=Notarized Developer ID`。公证后 SHA-256 为 `72f3455453a4d8b8fe20f1b6ee2de97695e6abfc5721911a98b2313d655de6e8`。该结果不是 App Store 审核或真实安装验收。
