# macOS 构建基线与正式发行边界

当前版本定位为**开发者预览，不是正式发行包**。Xcode 工程统一构建句译 SwiftUI App 和兼容 Apple Translation helper，但尚无已完成 Developer ID 签名、公证的公众下载包。Apple 主链由原生 App 负责双 Option、AX 取词、端上翻译和浮窗；当前仍需 Hammerspoon 通过既有 owner 协议让出旧链。Python 后端只服务可选云端和旧兼容路径，不是预编译原生 Apple 运行的必要依赖。

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

本轮产品改进候选为 `0.4.0`、build `9`。这是源码中的版本标识，不代表已完成安装或真机验收。以后生成新的实机候选包前应递增 build，避免与已安装的同版本产物混淆；实际证据应记录运行包的版本、构建号和路径，不能用旧版截图证明新版通过。

## 本地构建

```bash
xcodebuild -project Juyi.xcodeproj -scheme Juyi \
  -configuration Debug -derivedDataPath /tmp/JuyiDebug build

xcodebuild -project Juyi.xcodeproj -scheme Juyi \
  -configuration Release -derivedDataPath /tmp/JuyiRelease build
```

共享 scheme 会构建 App 与 helper。helper 仍由源码安装流程放到现有服务目录，供旧服务兼容；当前原生 Apple 选区翻译、诊断自测与语言包准备直接使用 App 内的 Translation framework，不调用这个 helper 或 Python 服务。

源码完整安装器要求 Homebrew、Python ≥ 3.10 和可用的 Xcode/Command Line Tools 编译环境。预编译 App 的 Apple 运行路径不要求这些构建工具，但仍需 macOS 15+、Hammerspoon、句译辅助功能权限和系统语言包。仅构建或拷贝 App 不等于安装器已解决全部首次使用前提。

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
2. 生成 Release 并使用 Developer ID 签名、Hardened Runtime 和 timestamp。当前 App 不内嵌 helper；如果另行分发兼容 helper，应对它单独签名并纳入公证容器。
3. 制作并签名最终 DMG/PKG，以最终分发容器提交 `notarytool` 公证；获准后 staple、验证票据与 Gatekeeper，再公布下载和校验值。
4. 为 Apple-first 产品提供可验证的完整安装体验，解决当前独立 Hammerspoon 依赖；若保留该依赖，应由发行流程明确交付与引导，而不是要求普通用户理解 owner 协议。可选云端所需的 Python 后台另行封装或明确标为高级安装，不得说成原生 Apple 必需运行时。
5. 在干净 macOS 账户完成下载、安装、授权、首次语言包准备、真实选区翻译、暂停、退出再开与升级验证；记录最低支持系统及不同硬件的实际兼容结果。

在这些步骤完成前，README 中的源码安装流程仍是开发/现有用户路径，不应把本地产物描述成已经可以面向公众双击安装的发行包。

本轮用户路径改进及待实测项见 [PRODUCT_REVIEW_2026-09-22.md](PRODUCT_REVIEW_2026-09-22.md)。CI 编译和策略测试可提供实现证据，不能替代真实 TCC 授权、语言包下载、App/PDF 取词或 Gatekeeper 安装验收。
