# 句译 0.4.0 · build 13（权限恢复修复公开测试版）

## 用户可感知的修复

修复一条权限恢复边界：延迟按键交付期间辅助功能权限失效，会移除原生监听。如果在再次返回句译前权限已恢复，旧实现可能仍显示“已就绪”但双 Option 不响应。

现在重新检查同时要求授权有效和监听仍在运行；若仅恢复了授权，句译通过既有的持久暂停、停止确认和 owner 重新启用流程恢复监听，不直接绕过互斥协议。没有新增 Lab、编译开关、服务或 owner 协议。

## 验证记录（2026-09-26）

- 现有监听器回归先在旧实现上失败，错误为 `restored trust without a monitor is not ready`；修复后通过，覆盖延迟交付时失权、先恢复授权、显式重建后手势再次可用。
- Python 回归通过；Universal 2 Release 构建通过，包含 arm64 与 x86_64，最低 macOS 15.0。
- 独立代理只读复核未发现新增恢复循环、暂停绕过或 owner 交接顺序问题，允许进入打包验证。
- 独立 build 13 App 与 DMG 已完成 Developer ID 签名、可信时间戳和 Hardened Runtime；Apple 公证 Accepted、DMG staple/validate 和 Gatekeeper 检查通过。最终 DMG SHA-256：`67c5a46bf7d5a2638262971f41b4d1cf4177af24a543ba4ee5b7624ae11ee3e6`。
- 上述检查不是系统 TCC 真机撤回/重授权或干净账户首次安装验收。build 12 的本机 TextEdit 成功不能直接作为 build 13 的真人结果。
- 本机已从上述正式 DMG 升级到 build 13，完整保留旧版备份。Computer Use 验证启动保持暂停、手动恢复显示就绪、从运行状态正常退出并结束进程、重新打开保持暂停、再次恢复显示就绪。未通过模拟按键声称真实翻译通过。
- 独立代理复核最终 DMG 与其中 App 的版本、两种架构、签名、票据、Gatekeeper 和校验文件一致，没有新增包级阻断；首次安装与真实选区仍按下方边界验收。

## 分发与验收边界

已作为[公开测试版](https://github.com/Eim-aa/juyi/releases/tag/v0.4.0-preview.13)发布，不是稳定版。匿名下载 DMG 与校验清单均为 HTTP 200；下载包 SHA-256 与本地最终包一致，stapler 与 Gatekeeper 验证通过，没有复用 build 12 的发行结果。

App 构建源码 `b4ad739` 的[完整 CI](https://github.com/Eim-aa/juyi/actions/runs/36159165104)通过。发布标签指向 `62a4ab1`，与该构建源码仅五份安装／发布文档不同；生产源码、构建配置与打包资源未改。后续文档同步的 CI 与该 App 代码检查分别记录，不合并宣称为同一个结果。

只在安装包签名、公证和下载校验通过后更新下载入口。旧包保留，不在原 build 12 标签下覆盖文件。

首次辅助功能授权、Apple 语言资源确认与真实全局双 Option 必须由本人完成。干净账户、此版本 PDF、关闭主窗口后的翻译、暂停时不触发、macOS 15 与 Intel 真机等仍须分别记录，未验证不等于已知失败。

安装仍为“下载 DMG → 拖入 Applications → 打开句译并授权 → 准备语言资源 → 选英文、双 Option”。全新 Apple 本地路径不要求 Hammerspoon、Python、Homebrew 或 API 密钥；有早期开发组件时保持既有 fail-closed 交接。
