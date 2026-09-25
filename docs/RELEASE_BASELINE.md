# macOS 构建基线与正式发行边界

当前版本定位为**公开测试版，不是稳定版**。build 12 已完成签名、公证并公开下载，且通过已有开发配置机器上的实际文本翻译验收，证据见 [build 12 发布记录](RELEASE_0.4.0_BUILD12.md)。该版本移除全新本地安装的 Hammerspoon 前提，但干净账户首次安装仍待实测。Apple 主链由原生 App 负责双 Option、AX 取词、端上翻译和浮窗；已有早期开发组件继续通过既有 owner 协议交接。Python 后端只服务可选云端和兼容路径。

## 工程与兼容性

- 工程：`Juyi.xcodeproj`，共享 scheme：`Juyi`。
- App target：`Juyi`，bundle id 保持 `io.github.Eim-aa.Juyi`。
- Helper target：`AppleTranslationHelper`，产物名为 `apple-translation-helper`。
- 最低系统：macOS 15.0。
- 架构：Apple Silicon `arm64` + Intel `x86_64`（Universal 2）。
- App Sandbox：关闭。当前控制中心需要管理现有用户级后台进程、LaunchAgent、钥匙串和 Hammerspoon，不能在没有架构改造的情况下直接启用沙盒。
- Hardened Runtime：工程设置已开启。默认 Xcode 本地构建的 ad-hoc 签名实测包含 `runtime` flag，但没有 Developer ID 身份、可信 timestamp 或公证，不能作为公开发行签名。CI 会传入 `CODE_SIGNING_ALLOWED=NO`，因此 CI 的 `.app` bundle 是未签名门禁产物，只验证编译、版本、架构和 deployment target，不做签名声明。

工程只显式引用需要的源码与资源，不使用仓库根目录同步文件组；本地辅助脚本或未跟踪文件不会自动进入 App bundle。Xcode 与兼容构建脚本都会把当前 `argos-translator.lua` 和 `hammerspoon_hook.sh` 放入 App Resources，供图形界面的 owner 模块部署流程使用。

`bootstrap.sh`、完整安装器和独立 App 安装器都会在下载/更新 checkout、创建 token/venv、修改服务或 Hammerspoon、构建、退出旧 App 之前独立检查 macOS 15。旧系统会直接退出并保留现有安装。

## 版本唯一来源

版本只在 `Config/Version.xcconfig` 的以下两个键修改：

```text
MARKETING_VERSION = <面向用户的版本号>
CURRENT_PROJECT_VERSION = <单调递增的整数 build>
```

`macos/Info.plist` 使用 Xcode 变量展开。发布时同时递增 build number；Release tag 应与 `v$(MARKETING_VERSION)` 一致，但 tag 不是反向生成版本的来源。

当前源码候选为 `0.4.0`、build `13`，权限恢复修复与验证边界见 [build 13 记录](RELEASE_0.4.0_BUILD13.md)。2026-09-26，已将已公证的 build 13 从正式 DMG 安装到 `/Applications/句译.app`，保留完整旧版备份，实测启动保持暂停、恢复显示就绪、正常退出和重开保持暂停。真实全局快捷键尚未计入本版验收。2026-09-25 用户确认的文本编辑双 Option 中文译文属于 build 12，不能直接算作 build 13 结果。系统为 macOS 26.5.1、Apple Silicon。此前 build 11 的 PDF 断词、长段落验收不等于 build 12/13 的 PDF 或首次安装已验收，也不代表 macOS 15 或 Intel 真机验收。实际证据必须记录运行包版本、构建号和路径，不能用旧版截图证明新版通过。

## 本地构建

```bash
xcodebuild -project Juyi.xcodeproj -scheme Juyi \
  -configuration Debug -derivedDataPath /tmp/JuyiDebug build

xcodebuild -project Juyi.xcodeproj -scheme Juyi \
  -configuration Release -derivedDataPath /tmp/JuyiRelease build
```

共享 scheme 会构建 App 与 helper。helper 仍由源码安装流程放到现有服务目录，供旧服务兼容；当前原生 Apple 选区翻译、诊断自测与语言包准备直接使用 App 内的 Translation framework，不调用这个 helper 或 Python 服务。

源码完整安装器要求 Homebrew、Python ≥ 3.10 和 Xcode/Command Line Tools。build 12 起预编译 App 的全新 Apple 运行路径不要求这些工具或 Hammerspoon，仍需 macOS 15+、句译辅助功能权限和系统语言包。已有开发组件的交接保持 fail-closed；仅构建成功不能替代首次使用验收。

现有无工程脚本仍可用于本地安装流程，并读取相同版本、架构和最低系统配置：

```bash
scripts/build_macos_app.sh
scripts/build_apple_helper.sh /tmp/apple-translation-helper
```

二者都会验证 Universal 2、每个 slice 的 macOS 15.0 deployment target。与上述 unsigned Xcode CI 产物不同，这两个兼容脚本会做 ad-hoc 签名，随后实际运行 `codesign --verify` 并检查签名的 `runtime` flag。该检查能证明 bundle 结构和 Hardened Runtime 选项正确，不能提供 Developer ID 信任、timestamp 或公证。

## CI 门禁

macOS CI 同时构建 Debug 与 Release Xcode 配置，并验证：

- App 与 helper 都包含 `arm64`、`x86_64`；
- 两个架构的 minimum OS 都是 15.0；
- App 的版本号来自 `Config/Version.xcconfig`；
- 旧安装脚本构建路径仍可用，并单独核验其 ad-hoc runtime 签名；
- Swift 策略测试、Python/Lua/Bash 契约继续通过。

## 发行状态与稳定版前仍需完成

2026-09-25：build 12 已独立完成 Developer ID 签名、Apple 公证、staple、Gatekeeper 以及匿名下载验证，并作为公开测试版发布。安装包源码对应提交的 GitHub CI 全部通过，本机升级后的真实文本翻译通过，完整证据见 build 12 发布记录，不沿用 build 11 结果。公证凭据已存于本机钥匙串，无需把私钥导出到 GitHub。打包脚本将 App、Applications 链接与离线说明放入 DMG，打包成功仍不等于公证成功。

1. 使用稳定的 Developer ID Application 团队；若日后改为 CI 签名，再配置临时 CI keychain，不将私钥提交到仓库。
2. 本地候选 App 已完成 Developer ID 签名、Hardened Runtime 和 timestamp。当前 App 不内嵌 helper；如果另行分发兼容 helper，应对它单独签名并纳入公证容器。
3. build 12 的最终 DMG 签名、公证、staple、票据与 Gatekeeper 验证、下载及校验值已完成。以后更改分发包仍需重新执行，不能复用旧包的公证结果。
4. build 12 已实现无 Hammerspoon 的全新原生启用路径；已有配置机器上的真实文本链路已通过，干净环境安装后仍需独立验证。可选云端的 Python 后台明确标为高级安装，不是原生 Apple 必需运行时。
5. 在干净 macOS 账户完成下载、安装、授权、首次语言包准备、真实选区翻译、暂停、退出再开与升级验证；记录最低支持系统及不同硬件的实际兼容结果。

公开测试包和稳定版应明确区分。每个下载包分别披露签名、公证及真实安装验证状态；不把源码构建或旧版本测试作为新版本的验收证据。

本轮用户路径改进及待实测项见 [PRODUCT_REVIEW_2026-09-22.md](PRODUCT_REVIEW_2026-09-22.md)。CI 编译和策略测试可提供实现证据，不能替代真实 TCC 授权、语言包下载、App/PDF 取词或 Gatekeeper 安装验收。
