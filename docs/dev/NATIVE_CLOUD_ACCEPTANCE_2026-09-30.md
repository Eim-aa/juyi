# 火山云端原生化验收记录 · 2026-09-30

对应计划：[NATIVE_CLOUD_PLAN_2026-09-30.md](NATIVE_CLOUD_PLAN_2026-09-30.md)。分支 `claude/native-cloud`，基线 `main` `0e3219c`（build 17）。验收环境同 [上一轮](SIMPLIFICATION_ACCEPTANCE_2026-09-29.md)；本机无火山密钥、无 Hammerspoon、无 Python 后台。

## 提交

| 阶段 | 提交 | 内容 |
| --- | --- | --- |
| 计划 | `7de06e8` | 方案 |
| 4A | `07c5550` | 原生 `VolcTranslationEngine`（V4 签名、URLSession、响应解析、错误映射），协调器按引擎分发且不回退，AppModel 云端流程改为内存验证 → 钥匙串保存，删除 pending 项与 removal marker，新增 3 个 Swift 套件与云端契约测试 |
| 4B | `56c3bfa` `f6317fa` `0c3973b` | 删除 Python 服务、helper CLI 与 target、launchd、Hammerspoon Lua、安装脚本、owner 交接 5 个文件及测试；新增 `LegacyComponentCleanup`（检测早期组件、一键移除、fail-closed）；暂停状态迁移到 UserDefaults；CI、契约测试、README/AGENTS/文档重写 |

分支相对 `main`：92 个文件，+4 294 / −11 381。`macos/` 11 436 → 10 192 行（21 个文件）；仓库不再含 Python 运行时代码、Lua、launchd 模板与 helper。

## 静态检查（4A、4B 各跑一次，均通过）

- `grep -rn JUYI_NATIVE …` 为空；4B 后 `54321`、`argos-translator.lua`、`hs-status.json`、`owner-request.json` 只出现在 `scripts/uninstall.sh` 与 `LegacyComponentCleanup.swift` 的清理路径中。
- Debug（warnings as errors）与 Release `xcodebuild` 成功；`verify_macos_binary.sh` Universal 2 / macOS 15.0。
- Release 二进制含 `NativeProductionTranslationCoordinator`、`NativeOptionMonitor`、浮窗 bundle id、`VolcTranslationEngine`、`translate.volcengineapi.com`、`LegacyComponentCleanup`；不含 `owner-request.json`、`127.0.0.1:54321`、`NativeOwnerActivationCoordinator`。`otool -L` 装载 `Translation.framework`，不装载 `Security.framework` / `LocalAuthentication.framework`。
- `scripts/build_macos_app.sh` 成功并通过签名校验。
- `scripts/run_swift_tests.sh`：4A 20 套件、4B 16 套件全部通过（新增 builder 90、parser 63、engine 61、cleanup 52 项断言；签名向量与 Python 实现一致）。
- `pytest`：4A 181 通过，4B 96 通过；`ruff` 通过；`bash -n scripts/*.sh` 通过。
- 人工复核：引擎不记录、不打印、不持久化凭据，请求只带签名头；候选密钥验证失败不写钥匙串；替换或移除密钥会清空内存缓存；云端失败不改用 Apple，Apple 失败不改用云端；本机现有 `~/.config/argos-translator` 中的 `hs-paused`/`native-owner.lock`/`owner-request.json` 被归为 housekeeping，不会触发“检测到早期组件”。

## 未在本机完成（需用户在安装到 /Applications 的构建上验证）

本会话无权限替换正在运行的已安装 App。请运行 `scripts/install_macos_app.sh` 后：

1. 启动后首页不出现“检测到早期组件”。
2. 翻译方式 → 使用云端翻译… → 输入真实 AK/SK → 保存并验证 → “火山云端已可用”。
3. 文本编辑选中英文 ⌥⌥：浮窗译文、元数据“火山云端 · N 毫秒”、朗读可用。
4. 断网重试：显示网络错误，不改用 Apple。
5. 切回本地 · Apple 翻译一次；诊断页在两种引擎下各测试一次。
6. 模拟早期组件（例如 `mkdir -p ~/.hammerspoon && touch ~/.config/argos-translator/hs-status.json`）后重新打开：出现提示，一键移除后可启用。

## 遗留

- 干净 Mac 上 `~/.config/argos-translator` 里的过期文件不会被自动清理（只在一键移除时删除），无功能影响。
- 4B 三个提交的 co-author 署名为 Opus 5.5（实际执行模型）。
- 长难句自动走云端与 `JuyiMenuBar.swift` 拆分仍在计划 §5。
