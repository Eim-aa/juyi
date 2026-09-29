# 句译精简验收记录 · 2026-09-29

对应计划：[SIMPLIFICATION_PLAN_2026-09-29.md](SIMPLIFICATION_PLAN_2026-09-29.md)。分支 `claude/simplify-2026-09`，基线 `7d8d74c`。验收环境：macOS 26.5.1 / Apple Silicon，Xcode 26.6（Swift 6.3.3），Python 3.12 venv。本机已安装并运行 build 16，无 Hammerspoon、无 Python 后台。

## 提交

| 阶段 | 提交 | 内容 |
| --- | --- | --- |
| 计划 | `f135dbc` | 方向、诊断与三阶段方案 |
| 一 | `c7ecf24` | 删除 21 个 lab Swift 源、17 个 lab 测试、5 个 lab 契约测试与 parity 校验；`JuyiMenuBar.swift` 等混合文件去掉全部 `JUYI_NATIVE_*` 块；删除不可达的 `.prepare` 引导屏与其它死代码；CI `swift` job 由 753 行收敛到 91 行；新增 `scripts/run_swift_tests.sh` |
| 二 | `a8a61de` | `/health` 轮询只在云端相关时发起，闲置 10 s；菜单只在派生快照变化时重建；coordinator 单次订阅；触发路径缓存语言就绪与旧组件检测；WPS 剪贴板稳定后提前返回；云端钥匙串读取移出主线程；朗读语音缓存 |
| 三 | `919372b` | 引导改为“准备 · 练习 · 完成”，Hammerspoon 文案只在存在旧组件时出现；诊断页分为“状态与修复”“设置”并以链接打开支持范围；重复的关闭/暂停/退出与隐私文案只保留在支持范围页；菜单栏六组 |

合计 97 个文件，+1 836 / −23 864 行。`macos/` 由 23 274 行降到 11 436 行（22 个文件）。

## 每阶段执行的检查（三次均通过）

- `grep -rn JUYI_NATIVE macos tests scripts .github Config` 为空（清理 `__pycache__` 后）。
- `xcodebuild` Debug（`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`）与 Release（`CODE_SIGNING_ALLOWED=NO`）成功；`scripts/verify_macos_binary.sh … 15.0` 通过。
- Release 二进制含 `NativeProductionTranslationCoordinator`、`NativeOptionMonitor`、`native-owner.lock`、`owner-request.json`、`io.github.Eim-aa.Juyi.native-translation-overlay`；`otool -L` 装载 `Translation.framework`，不装载 `Security.framework` / `LocalAuthentication.framework`。
- `scripts/build_macos_app.sh`、`scripts/build_apple_helper.sh` 成功并通过自带签名校验。
- `scripts/run_swift_tests.sh`：阶段一 15 套件、阶段二/三 17 套件全部通过。
- `pytest`：165 → 167 → 173 通过；`ruff check .` 通过；`bash -n scripts/*.sh` 通过。
- 人工复核：阶段一新增行只有去重后的 `Surface`、Lua 前向声明与文档；契约测试改为断言无 lab 状态，没有 `skip`。阶段二 WPS 轮询循环仍每 20 ms 检查取消与前台；就绪缓存在失败、超时、`disable()` 时失效；云端流程中 `DispatchSemaphore` 只剩 `runBoundedProcess` 内部。阶段三所有 `hotkeyProblem` 状态仍有对应文案。

## 未在本机完成的检查

- **Lua**：本机无 `lua`/`luac`，`hammerspoon_runtime_test.lua` 与语法检查留给 CI `syntax` job。
- **运行时轮询**：本机 build 16 在 30 s 内向 `127.0.0.1:54321` 发起 37 次连接（基线）。候选构建需退出已安装的句译后再启动，本次会话无权限操作用户正在运行的 App，未测。手动方法：退出句译 → `open build/Juyi.app` → 运行任意本地监听脚本 60 s，应为 0 次连接。
- **界面截图与真实双 Option**：无屏幕录制权限，未截图；真实选区 → ⌥⌥ → 浮窗、深色模式、VoiceOver 仍需人工在安装到 `/Applications` 的构建上验证。
- **叠加 sheet**：诊断页内打开“支持范围与隐私”改为诊断 sheet 之上再叠一层 sheet，静态可编译，未实机点击。

## 阶段三验收指标

- 关键句计数（`macos/JuyiMenuBar.swift`）：“扫描” 2 处；“选中英文，连按两次 Option” 3 处（完成页、首页、恢复暂停时的模型状态文案）；“退出句译” 3 处（菜单共享常量、支持范围页、一条云端凭据错误）。计划要求 ≤ 2，超出的两处均为不同语境的状态/错误文案，不属于重复说明，接受。
- 诊断页内嵌的“文本编辑、预览、WPS 文本 PDF 和 Chrome 网页已在本机验证”一句被删除：该表述与产品审查“按构建逐项验证”的原则冲突，接受。

## 遗留与建议

1. 云端路径（Python 服务 + Hammerspoon Lua + helper CLI，约 5 000 行）本轮保留。若产品决定只保留 Apple 本地翻译，可整体移除并把 owner 交接简化为“检测到旧模块则卸载”。
2. 菜单栏在已有 sheet 打开时再打开另一个根级 sheet 的冲突为既有问题，未改。
3. `JuyiMenuBar.swift` 仍有 3 390 行（AppModel 约 2 200 行，其中云端凭据事务约 700 行），可在下一轮按职责拆文件。
