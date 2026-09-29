# 从源码构建句译

只想使用句译，请直接从 [GitHub Releases](https://github.com/Eim-aa/juyi/releases) 下载已签名、公证的 DMG。本页面向想修改或自行构建 App 的开发者。

## 需要

- macOS 15 或更新版本
- Xcode（CI 使用 GitHub `macos-15` 镜像自带的版本）

构建原生 App 不需要 Python、Homebrew 或 Hammerspoon。

## 用 Xcode 构建

打开 `Juyi.xcodeproj`，选择 scheme `Juyi` 后运行。也可以用命令行构建：

```bash
xcodebuild -project Juyi.xcodeproj -scheme Juyi -configuration Release \
  -derivedDataPath /tmp/JuyiRelease build
```

产物位于 `/tmp/JuyiRelease/Build/Products/Release/Juyi.app`。版本号只在 `Config/Version.xcconfig` 中修改。

## 安装自己构建的版本

```bash
scripts/install_macos_app.sh
```

脚本会构建 Universal 2 App，做本地 ad-hoc 签名并校验，再安装到 `/Applications/句译.app`。替换前会退出正在运行的句译。

自行构建的 App 没有 Developer ID 签名，也没有经过公证，只适合本机开发。签名与下载版不同时，macOS 可能要求你重新为句译开启「辅助功能」权限。不要关闭 Gatekeeper 或绕过系统权限。

## 运行测试

- Python 与契约测试：`python -m pip install -r requirements-dev.txt`，然后运行 `python -m pytest`。
- Swift 单元测试：`scripts/run_swift_tests.sh`（本地与 CI 共用，逐个用 `swiftc` 编译并运行 `tests/*Tests.swift` 中的 17 个生产套件）。

## 仓库结构

| 路径 | 用途 |
|---|---|
| `macos/`、`Juyi.xcodeproj`、`Config/` | 句译原生 App：双 Option 识别、取词、Apple 翻译与浮窗 |
| `apple/` | Apple 翻译命令行 helper（编译为 `bin/apple-translation-helper`），供可选后台和早期安装使用 |
| `tests/` | Python 契约测试与 Swift 单元测试 |
| `docs/` | 使用说明、发布记录（`releases/`）、开发记录（`dev/`） |
| 根目录 `*.py`、`requirements.txt`、`launchd/` | 可选的火山云端后台服务，本地 Apple 翻译不需要 |
| `hammerspoon/`、`scripts/hammerspoon_hook.sh` | 早期安装的兼容组件；build 12 起的新安装不需要 |
| `scripts/` | 构建、打包与可选后台的安装脚本 |

可选云端后台的源码安装步骤见 [使用与排查](MENU_BAR_APP.md#安装)。发布流程与验收边界见 [构建与发布基线](RELEASE_BASELINE.md)。
