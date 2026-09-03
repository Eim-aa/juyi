# macOS 公开版构建基线

当前仓库已经有可提交的原生 Xcode 工程基座。它统一构建句译 SwiftUI App 和 Apple Translation helper，但**还不是可直接公开分发的签名、公证安装包**。生产 Apple 链已由原生 App 负责双 Option 监听、AX 取词、端上翻译和浮窗；Hammerspoon 只通过现有 owner 协议让出旧链，Python 后端继续服务可选云端和兼容路径。

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

当前值是本阶段沿用的工程基线。生成下一份实机重装包或任何公开候选包之前，必须先在这里递增版本与 build，避免与已经安装的同版本产物混淆。

## 本地构建

```bash
xcodebuild -project Juyi.xcodeproj -scheme Juyi \
  -configuration Debug -derivedDataPath /tmp/JuyiDebug build

xcodebuild -project Juyi.xcodeproj -scheme Juyi \
  -configuration Release -derivedDataPath /tmp/JuyiRelease build
```

共享 scheme 会构建 App 与 helper。helper 目前仍由安装流程放到现有服务目录；Xcode 中生成 helper 并不表示 App 已经内嵌或切换到该路径。

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

## 公开发布前仍需完成

1. 配置稳定的 Developer ID Application 团队与临时 CI keychain。
2. 用 Xcode Archive/Export 生成 Release；先签 helper，再签 App，启用 Hardened Runtime 与 timestamp。
3. 完成 `notarytool` 公证、staple、Gatekeeper 验证，再制作并签名 DMG/PKG。
4. 把仍需的 Python 运行时、后端与 Hammerspoon owner 桥接打包进单一安装体验，或在后续架构阶段消除这些兼容依赖；全局 Apple 触发链已经是原生实现。

在这些步骤完成前，README 中的源码安装流程仍是开发/现有用户路径，不应把本地产物描述成已经可以面向公众双击安装的发行包。
