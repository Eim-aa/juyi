# 句译 0.4.0 · build 11（待发布草稿）

此版本尚未公开发布。安装包的 Developer ID 签名不等于 Apple 公证；在公证、Gatekeeper 和首次安装验收完成前，不提供正式下载承诺。

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
- [ ] 最新提交的 GitHub CI 完成。
- [ ] 最终 DMG 公证 Accepted、staple 及 Gatekeeper 检查。
- [ ] 干净账户首次安装、辅助功能、首次语言包、双 Option、退出重开和升级回退。
- [ ] macOS 15 / Intel 实际硬件兼容性验证（构建包含架构不代表实测）。

当前工作机为 Apple Silicon、macOS 26.5.1。不会重置用户现有 TCC 或删除语言包来冒充干净环境。App Store 版本另见 [可行性评估](APP_STORE_FEASIBILITY.md)。
