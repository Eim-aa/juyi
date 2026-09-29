# macOS 构建基线与正式发行边界

当前版本定位为**公开测试版，不是稳定版**。build 16 新增原生译文浮窗的本机朗读，用户已确认本机试用可用；保留 build 15 的取词反馈改进。最终包的签名、公证、CI、公开下载与真人验收范围以 [build 16 发布记录](releases/RELEASE_0.4.0_BUILD16.md)及对应 GitHub Release 为准。间歇性“不支持”的根因未确证，干净账户首次安装、macOS 15 / Intel 真机未完成。build 12 起已移除全新本地安装的 Hammerspoon 前提。源码 build 17 起（阶段 4A/4B），原生 App 独立负责双 Option、AX 取词、Apple 与火山翻译、浮窗和朗读；Python 后台、Hammerspoon owner 交接与 Apple helper CLI 已从仓库移除，早期组件由 App 检测并在用户一键移除后才启用双 Option。

## 工程与兼容性

- 工程：`Juyi.xcodeproj`，共享 scheme：`Juyi`。
- App target：`Juyi`，bundle id 保持 `io.github.Eim-aa.Juyi`。
- 最低系统：macOS 15.0。
- 架构：Apple Silicon `arm64` + Intel `x86_64`（Universal 2）。
- App Sandbox：关闭。App 需要辅助功能全局按键与选区读取、通过 `/usr/bin/security` 访问钥匙串、管理登录项兼容 LaunchAgent，并清理早期组件（`~/.hammerspoon`、`~/Library/LaunchAgents`、`~/.config/argos-translator`），不能在没有架构改造的情况下直接启用沙盒。
- Hardened Runtime：工程设置已开启。默认 Xcode 本地构建的 ad-hoc 签名实测包含 `runtime` flag，但没有 Developer ID 身份、可信 timestamp 或公证，不能作为公开发行签名。CI 会传入 `CODE_SIGNING_ALLOWED=NO`，因此 CI 的 `.app` bundle 是未签名门禁产物，只验证编译、版本、架构和 deployment target，不做签名声明。

工程只显式引用需要的源码与资源，不使用仓库根目录同步文件组；本地辅助脚本或未跟踪文件不会自动进入 App bundle。App Resources 只包含图标与资源目录，不再携带 Hammerspoon 模块或脚本。

App 安装器 `scripts/install_macos_app.sh` 在构建、退出旧 App 或替换之前检查 macOS 15。旧系统会直接退出并保留现有安装。

## 版本唯一来源

版本只在 `Config/Version.xcconfig` 的以下两个键修改：

```text
MARKETING_VERSION = <面向用户的版本号>
CURRENT_PROJECT_VERSION = <单调递增的整数 build>
```

`macos/Info.plist` 使用 Xcode 变量展开。发布时同时递增 build number；Release tag 应与 `v$(MARKETING_VERSION)` 一致，但 tag 不是反向生成版本的来源。

当前源码为 `0.4.0`、build `16`。2026-09-27，已将 Developer ID 签名的本地朗读试用包安装到 `/Applications/句译.app`，完整保留 build 15 备份，启动及恢复就绪已核验；用户随后反馈「可以了」。系统为 macOS 26.5.1、Apple Silicon。这不是干净安装、全部生命周期或各硬件配置逐项验收。历史各版本验收不自动沿用；实际证据必须记录运行包版本、构建号和路径，不能用旧版截图证明新版通过。

## 本地构建

```bash
xcodebuild -project Juyi.xcodeproj -scheme Juyi \
  -configuration Debug -derivedDataPath /tmp/JuyiDebug build

xcodebuild -project Juyi.xcodeproj -scheme Juyi \
  -configuration Release -derivedDataPath /tmp/JuyiRelease build
```

共享 scheme 只构建 App。原生选区翻译、诊断自测与语言包准备直接使用 App 内的 Translation framework；火山云端由 App 内的 V4 签名器直连 `translate.volcengineapi.com`。

运行时只需要 macOS 15+、句译辅助功能权限，以及 Apple 语言包或火山密钥。早期组件检测保持 fail-closed；仅构建成功不能替代首次使用验收。

无工程脚本仍可用于本地安装流程，并读取相同版本、架构和最低系统配置：

```bash
scripts/build_macos_app.sh
```

它会验证 Universal 2、每个 slice 的 macOS 15.0 deployment target。与上述 unsigned Xcode CI 产物不同，该脚本会做 ad-hoc 签名，随后实际运行 `codesign --verify` 并检查签名的 `runtime` flag。该检查能证明 bundle 结构和 Hardened Runtime 选项正确，不能提供 Developer ID 信任、timestamp 或公证。

## CI 门禁

macOS CI 同时构建 Debug（warnings as errors）与 Release Xcode 配置，并验证：

- App 包含 `arm64`、`x86_64`，且不再产出 `apple-translation-helper`；
- 两个架构的 minimum OS 都是 15.0；
- App 的版本号来自 `Config/Version.xcconfig`；
- 生产原生链路的关键符号（含 `VolcTranslationEngine`、`LegacyComponentCleanup`）与 `translate.volcengineapi.com` 存在，已移除的 owner 交接符号与本地服务地址不存在；二进制装载 `Translation.framework`，不装载 `Security.framework` / `LocalAuthentication.framework`；
- 安装脚本构建路径（`scripts/build_macos_app.sh`）仍可用，并单独核验其 ad-hoc runtime 签名；
- `scripts/run_swift_tests.sh` 中的 Swift 单元测试、Python 静态契约（pytest + ruff）与 Bash 语法检查继续通过。

2026-09 起仓库不再包含 Debug lab 或 `JUYI_NATIVE_*` 编译开关，CI 只构建与测试生产代码。

## 发行状态与稳定版前仍需完成

2026-09-25：build 12 已独立完成 Developer ID 签名、Apple 公证、staple、Gatekeeper 以及匿名下载验证，并作为公开测试版发布。安装包源码对应提交的 GitHub CI 全部通过，本机升级后的真实文本翻译通过，完整证据见 build 12 发布记录，不沿用 build 11 结果。公证凭据已存于本机钥匙串，无需把私钥导出到 GitHub。打包脚本将 App、Applications 链接与离线说明放入 DMG，打包成功仍不等于公证成功。

1. 使用稳定的 Developer ID Application 团队；若日后改为 CI 签名，再配置临时 CI keychain，不将私钥提交到仓库。
2. 本地候选 App 已完成 Developer ID 签名、Hardened Runtime 和 timestamp。App 不内嵌任何 helper 可执行文件。
3. build 12 的最终 DMG 签名、公证、staple、票据与 Gatekeeper 验证、下载及校验值已完成。以后更改分发包仍需重新执行，不能复用旧包的公证结果。
4. build 12 已实现无 Hammerspoon 的全新原生启用路径；源码 build 17 起云端也不再需要后台。已有配置机器上的真实文本链路已通过，干净环境安装、火山云端真实密钥与早期组件一键移除仍需人工验收。
5. 在干净 macOS 账户完成下载、安装、授权、首次语言包准备、真实选区翻译、暂停、退出再开与升级验证；记录最低支持系统及不同硬件的实际兼容结果。

公开测试包和稳定版应明确区分。每个下载包分别披露签名、公证及真实安装验证状态；不把源码构建或旧版本测试作为新版本的验收证据。

本轮用户路径改进及待实测项见 [PRODUCT_REVIEW_2026-09-22.md](dev/PRODUCT_REVIEW_2026-09-22.md)。CI 编译和策略测试可提供实现证据，不能替代真实 TCC 授权、语言包下载、App/PDF 取词或 Gatekeeper 安装验收。
