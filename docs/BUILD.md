# 从源码构建句译

只想使用句译，请直接从 [GitHub Releases](https://github.com/Eim-aa/juyi/releases) 下载已签名、公证的 DMG。本页面向想修改或自行构建 App 的开发者。

## 需要

- macOS 15 或更新版本
- Xcode（CI 使用 GitHub `macos-15` 镜像自带的版本）

构建与运行句译都不需要 Python、Homebrew 或 Hammerspoon。Python 只用于运行仓库的静态契约测试。

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

- 契约测试：`python -m pip install -r requirements-dev.txt`（只含 pytest 与 ruff），然后运行 `python -m ruff check tests` 与 `python -m pytest tests`。这些测试只读取仓库文件，不安装或启动任何服务。
- Swift 单元测试：`scripts/run_swift_tests.sh`（本地与 CI 共用，逐个用 `swiftc` 编译并运行 `tests/*Tests.swift` 中的 16 个生产套件）。

## 仓库结构

| 路径 | 用途 |
|---|---|
| `macos/`、`Juyi.xcodeproj`、`Config/` | 句译原生 App：双 Option 识别、取词、Apple 与火山翻译、浮窗与朗读、早期组件清理（`LegacyComponentCleanup.swift`） |
| `tests/` | Swift 单元测试（`*Tests.swift`）与 Python 静态契约测试（`test_*.py`） |
| `docs/` | 使用说明、发布记录（`releases/`）、开发记录（`dev/`） |
| `scripts/` | 构建、测试、打包、校验、安装 App 与卸载脚本 |

2026-09-30（阶段 4B）起，仓库不再包含 Python 后台服务、LaunchAgent 模板、Hammerspoon Lua 模块、Apple 翻译命令行 helper 及其安装脚本；火山云端由 App 直连。发布流程与验收边界见 [构建与发布基线](RELEASE_BASELINE.md)。
