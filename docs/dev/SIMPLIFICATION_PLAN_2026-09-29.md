# 句译精简计划 · 2026-09-29

目标：**清理界面、精简代码与系统、优化性能**，同时不改变已发布的 Apple 本地翻译用户路径（双 Option → 辅助功能取词 → Apple Translation → 原生浮窗 → 朗读）。

角色分工：方向与方案（本文）→ 开发实施（按阶段）→ 验收 → 修复。每阶段单独提交，验收通过后才进入下一阶段。

## 1. 现状诊断（基线 `7d8d74c`，2026-09-29）

| 维度 | 事实 |
| --- | --- |
| Swift 源码 | `macos/` 41 个文件、23 274 行。其中 **21 个文件、10 416 行**整文件包在 `#if DEBUG && JUYI_NATIVE_*` 内，Release 与默认 Debug 都不编译；`JuyiMenuBar.swift`（3 933 行）另含约 70 处 lab 条件块。 |
| 编译开关 | 10 个 `JUYI_NATIVE_*` 开关，任何 xcconfig 都未启用；`JUYI_NATIVE_OPTION_MONITOR`、`JUYI_NATIVE_OWNER_ACTIVATION_LAB` 已无生产代码引用。 |
| 测试 | 32 个 Swift 测试可执行文件 + 1 个 parity runner，其中 **17 个（8 023 行）只测 lab 代码**；5 个 Python 契约测试 + parity 校验只钉住 lab 的存在。 |
| CI | `swift` job 有 40 次 `xcodebuild`、26 次 `build_macos_app.sh`、33 次 `swiftc`，绝大多数用于验证“lab 没有泄漏进产物”。估算串行 1h45–2h30；与生产相关的部分约 15–25 min。 |
| 生产链路 | 完全原生进程内：`NativeProductionTranslationCoordinator`（`NativeOptionFeature.swift`）→ `NativeOptionMonitor`（`NSEvent` 全局监听）→ `NativeSelectionReader` → `NativeAppleProductionTranslationService`（`NativeAppleTranslationAdapterHost.swift:314+`）→ `NativeTranslationOverlayController`。Release 中**没有任何原生火山 HTTP 客户端**；云端模式由 Hammerspoon Lua + Python 服务承担。 |
| 性能热点 | `AppModel` 每 2.5 s 无条件 `GET /health`（Apple-only 机器上端口根本不存在）+ 读 3 个文件 + 全量重建 `NSMenu`；coordinator 状态变化被两处订阅、菜单重建两次；每次双 Option 触发前都同步等待 `LanguageAvailability` 和 `requiresLegacyHandoff`（lstat + runningApplications）；WPS 剪贴板路径固定忙等 2 × 1.2 s；云端配置/移除在主线程同步 spawn `/usr/bin/security`（最长 8 s）。 |
| 界面冗余 | 引导有 5 个枚举屏但 `.prepare` 不可达（进度条却写“欢迎 · 准备 · 练习 · 完成”）；权限页 14 种状态文案 + 15 种脚注，多数是 Hammerspoon 旧路径；隐私/支持范围文案在 4 处重复；关闭/暂停/退出说明在 3 处重复；诊断页把状态、修复、隐私、登录项、测试、重跑设置塞进一个滚动区。 |

## 2. 方向与原则

1. **删除而不是继续门控**：Lab/flag 是迁移期脚手架，生产链已稳定，全部移除。不新增任何编译开关。
2. **生产行为不变**：双 Option 手势参数、owner 交接协议（`owner-request.json` / `hs-status.json` / `native-owner.lock`）、AX 取词策略、WPS 剪贴板恢复、浮窗交互、朗读、云端凭据事务、登录项逻辑，语义一律不改；只允许去重、缓存、调线程。
3. **本轮不动云端与旧组件**：Python 服务、Lua 模块、`hammerspoon_hook.sh`、安装/卸载脚本、helper CLI 保持可用（只删 Lua 中已确认的死函数）。是否彻底移除云端路径是产品决策，留给下一轮。
4. **每阶段可独立构建、测试、验收**；契约测试随代码同步改写，不允许用 `skip` 绕过。
5. **禁止事项**：不读取/修改/提交 `scripts/start_service.command`，不查看 `tmp/`；不改 bundle id、Info.plist、entitlements、签名与版本号；不引入新依赖、网络字体或网页运行时。

## 3. 阶段一：移除 Lab 脚手架（系统精简）

### 3.1 删除整文件（21 个 Swift 源）

`NativeSelectionCaptureLabModel/Host`、`NativeOwnerHandoffLabModel/Host`、`NativeTranslationDomain`、`VolcV4RequestBuilder`、`VolcTranslationResponseParser`、`NativeAppleTranslationAdapterModel`、`NativeVolcDebugCredentialStore/Interlock/Transport/Workflow`、`NativeVolcTranslationAdapterModel/Host`、`NativeTranslationOverlayExternalPresentation`、`NativeTranslationResultLabPresentation/Model/Host`、`NativeTranslationAppleResultLabBindingPresentation/Model/Host`。

### 3.2 混合文件：只保留生产部分

- `NativeAppleTranslationAdapterHost.swift`：删除 1–312 行的 lab 半部，保留 `// MARK: - Production Apple Translation host` 之后的 `NativeAppleProductionReadiness` / `NativeAppleProductionTranslationService` / `NativeAppleProductionTranslationHost`。建议把文件改名为 `NativeAppleTranslationService.swift`（同步 pbxproj、`build_macos_app.sh`、契约测试）。
- `JuyiMenuBar.swift`：删除全部 `#if DEBUG && JUYI_NATIVE_*` 块（约 70 处，含两段互斥的 `extension AppDelegate: NSMenuItemValidation`，以及 lab 菜单项、lab sheet、lab 协调器属性）。
- `NativeTranslationOverlayController.swift`：删除 fixture 矩阵（7–171）、`showFixturePreview`、`beginExternal`/`resolve*External`/`reserveRealAppleExternal`/`activateRealAppleExternal`/`updateRealAppleLoading`/`invalidate` 等 external 路径及其它 lab 块；`focusCurrentOverlay()` 无生产调用方，一并删除。
- `NativeTranslationOverlayModel.swift`、`NativeTranslationOverlayInteractionPolicy.swift`：删除各自的 lab 块。
- 删除后 `grep -rn 'JUYI_NATIVE' macos/ tests/ scripts/ .github/ Config/` 必须为 0（文档除外）。

### 3.3 顺手删除的生产死代码

- `AppModel`：不可达的 `.prepare` 引导屏及其附属（`prepare` 视图、`engineStatusCard/engineStatus/engineFooter`、`verifyOnboardingEngine`/`retryOnboardingEngine`、`onboardingEngineChecking/Ready/Result`、`appleNeedsPreparation`、`applePreparing`、`prepareApple` 的 helper 二进制分支、7 处 `onboardingScreen == .prepare` 判断）。注意 `prepareApple` 的原生分支（Apple 语言包准备）是诊断页在用的，必须保留。
- 未使用：`EngineCard`、`pill(_:)`、`statusSymbol`/`statusColor`、`appleHelperInstalled`、`Health.auth_required/default_engine`、`OnboardingPolicy.firstIncompleteScreen(serviceReady:engineReady:hotkeyReady:)`。
- `hammerspoon/argos-translator.lua`：`rebuildMenu`、`setEngine`、`ENGINE_SHORT`、`M.stop`（无调用方；`M.start` 已删除 menubar）。改动后 `tests/hammerspoon_runtime_test.lua` 与 `test_hammerspoon_reliability_contract.py` 必须仍通过。
- `scripts/bench.sh`、`scripts/bench_ipc.py`、`scripts/demo.sh`（无引用；结论已写入 `config.py`）。

### 3.4 测试与 CI

- 删除 lab-only Swift 测试（17 个，见 §1）及 `tests/test_native_translation_domain_contract.py`、`test_native_selection_capture_lab_contract.py`、`test_native_translation_result_lab_contract.py`、`test_native_translation_apple_result_lab_binding_build_contract.py`、`test_native_volc_translation_adapter_contract.py`、`tests/check_native_translation_parity.py`、`tests/fixtures/native_translation_parity_v1.json`。
- 改写混合契约测试：`test_native_apple_translation_adapter_contract.py`（只保留生产 host 与 macOS 15 surface 检查）、`test_native_owner_handoff_contract.py`（去掉模块级读取 Lab 文件与 lab 断言，保留协议/store/workflow/status/activation/Lua 断言）、`test_native_translation_overlay_contract.py`（去掉 GATE、`showFixturePreview`、`JuyiOverlayPreview` 等断言）。
- 四个生产 Swift 测试去掉外层 `#if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB` / `JUYI_NATIVE_OWNER_ACTIVATION_LAB`：`NativeOwnerHandoffStoreTests`、`NativeOwnerHandoffWorkflowTests`、`NativeOwnerHandoffStatusReaderTests`、`NativeOwnerActivationCoordinatorTests`。
- 新增 `scripts/run_swift_tests.sh`：本地与 CI 共用，按 `tests/*Tests.swift` 逐个 `swiftc -parse-as-library … -o` 并执行（沿用现有 CI 的编译方式、`-warnings-as-errors`），列出 15 个保留套件。
- `.github/workflows/ci.yml` 的 `swift` job 收敛为：Report toolchain → Build Xcode Debug → Build Xcode Release → Verify Xcode Release products（版本、arch、minos）→ Verify production native chain（保留生产 token 与 `Translation.framework` 装载检查，去掉 lab 分离检查）→ `scripts/build_macos_app.sh` + `scripts/build_apple_helper.sh` → `scripts/run_swift_tests.sh`。`python`、`syntax` job 不变。`test_macos_install_contract.py` 钉住的 CI 字符串（`runs-on: macos-15`、`xcodebuild -quiet -project Juyi.xcodeproj -scheme Juyi`、Debug/Release、三个脚本名）必须保留。
- `scripts/build_macos_app.sh`：删除 Debug 下的 `JUYI_NATIVE_*` 转发块与 `HAS_NATIVE_*` 变量，源文件列表与 pbxproj 同步（`test_xcode_project_contract.py` 要求 pbxproj 保持显式 group，且 `baseConfigurationReference` 计数为 4）。`-framework Translation` 改为无条件链接。
- `Juyi.xcodeproj/project.pbxproj`：移除 21 个文件的 `PBXFileReference`、`PBXBuildFile`、group 与 Sources 条目。

### 3.5 文档

- `docs/BUILD.md`、`docs/RELEASE_BASELINE.md`（CI 门禁一节）、`docs/README.md` 更新为无 lab 的描述；`docs/dev/NATIVE_*` 文档顶部加一行“历史记录：lab 与编译开关已于 2026-09 移除”，不重写正文。
- `AGENTS.md`、`README*.md` 不需要改。

### 3.6 阶段一验收标准

1. `grep -rn JUYI_NATIVE macos tests scripts .github Config` 为空。
2. `xcodebuild … -configuration Debug`、`-configuration Release` 均成功（`CODE_SIGNING_ALLOWED=NO`），Release 二进制 `strings` 含 `NativeProductionTranslationCoordinator`、`NativeOptionMonitor`、`native-owner.lock`、`owner-request.json`、`io.github.Eim-aa.Juyi.native-translation-overlay`，`otool -L` 含 `Translation.framework`，不含 `Security.framework`/`LocalAuthentication.framework`。
3. `scripts/build_macos_app.sh` 成功并通过自带校验；`scripts/build_apple_helper.sh` 成功。
4. `scripts/run_swift_tests.sh` 15 个套件全部通过；`python -m pytest`、`python -m ruff check .`、`luac -p` / `lua5.4 tests/hammerspoon_runtime_test.lua`（若本机有 lua）、`bash -n scripts/*.sh` 通过。
5. `macos/` 总行数 ≤ 12 500；`ci.yml` ≤ 120 行。
6. 提交信息说明删除了哪些组件；diff 中不出现任何密钥或 `start_service.command`。

## 4. 阶段二：性能

所有改动都要有对应的单元测试或可复现的度量（`os_signpost`/日志计时可选）。

| # | 位置 | 问题 | 方案 | 验收 |
| --- | --- | --- | --- | --- |
| P1 | `JuyiMenuBar.swift:274` `refresh()` 2.5 s 定时器 | Apple-only 机器每 2.5 s 向不存在的端口发 HTTP，且每次全量重建菜单 | 只在“云端引擎被选中 / 云端配置或诊断 sheet 打开 / 已安装 LaunchAgent plist”时才请求 `/health`；否则只读本地状态文件。菜单与状态标签只在派生状态快照（一个 `Equatable` struct）变化时重建。定时器闲置时降到 10 s，前台激活或 sheet 打开时恢复 2.5 s。 | 在无服务机器上 60 s 内 0 次 HTTP；状态不变时 `updateChrome` 不重建菜单（单测覆盖快照比较）。 |
| P2 | `AppModel.init:277-283` 与 `AppDelegate:3401-3405` | coordinator `objectWillChange` 双订阅，菜单重建两次 | 只保留一处（AppModel），AppDelegate 通过 AppModel 的 `onChange` 更新 chrome | 单次状态变化只触发一次 `updateChrome` |
| P3 | `hammerspoonInstalled`（`NSWorkspace.urlForApplication`）在每次派生属性计算时调用 | LaunchServices 查询在每个 tick 多次执行 | 在 `refresh()` 里计算一次存入属性；派生属性只读属性 | 每 tick ≤ 1 次查询 |
| P4 | `NativeOptionFeature.swift:671-679` 每次触发都 `await apple.readiness()` 与 `requiresLegacyHandoff` | 触发到开始取词之间多一次 `LanguageAvailability` 往返和两次 lstat | readiness：成功后缓存，仅在翻译失败、语言包准备、唤醒、权限变化时失效；legacy 检测：在 enable 时和 `didLaunchApplicationNotification` 时计算并缓存，触发时只读缓存 | 触发到 `capture.capture` 调用之间无 await 系统 API（单测用注入的 fake 计数） |
| P5 | `NativeSelectionReader.swift:1319-1344` WPS 剪贴板轮询 | 固定跑满 1.2 s × 2，每轮迭代都做 AX 窗口查询 | 候选文本连续两次相同即提前退出；`isCurrentWPSPDFContext` 在循环外判定一次、循环内每 200 ms 复查一次 | `NativeSelectionReaderTests` 增加“稳定后提前返回”用例；WPS 路径最长时间不变（超时语义不变） |
| P6 | `JuyiMenuBar.swift` `configureCloud`/`removeCloud`/`validateExistingCloud` | 主线程同步 `runBoundedProcess` 调 `/usr/bin/security` | 统一经 `Task.detached` 执行，结果回到 MainActor；保留事务顺序 | 主线程无 `DispatchSemaphore.wait` 调用（grep 校验 + 契约测试） |
| P7 | `NativeTranslationOverlayController.swift:1779-1796` | 每次点击朗读都枚举并排序 `speechVoices()` | 首次使用后缓存，监听 `AVSpeechSynthesizer` 语音变更通知（若无通知则按会话缓存） | 第二次点击不再枚举 |
| P8 | `applicationBecameActive:849-858` | 每次激活 refresh 两次 + `SMAppService.status` + launchd 迁移 | 迁移只在首次激活执行一次；第二次 refresh 保留（服务状态可能变化）但 `SMAppService.status` 改为在登录项 sheet 可见时才查询 | 激活路径的系统调用次数下降，行为不变 |

不做：AX 单次超时值、双 Option 时间窗、浮窗动画时长、12 s 翻译超时——这些是产品行为，不属于本轮。

### 阶段二验收标准

- 阶段一全部检查继续通过。
- 新增/修改的 Swift 测试覆盖 P1、P2、P4、P5；`run_swift_tests.sh` 全绿。
- 手动：Apple-only 机器上打开 App 60 s，`lsof -i :54321` 与网络日志无请求；双 Option 后浮窗出现无可感知退化。

## 5. 阶段三：界面清理

原则：沿用现有系统语义色、材质、字号；只减不加；所有文案改动同步 `docs/MENU_BAR_APP.md` 与契约测试。

1. **首次设置**：`OnboardingScreen` 收敛为 `welcome / permission / practice / complete`（删 `.prepare`，阶段一已做），进度条与“第 N 步”标题与真实步数一致（3 步 + 完成）。权限页状态文案按“全新原生安装”与“存在旧组件”两组重排，旧组件相关文案只在 `requiresLegacyHandoff` 为真时出现；合并含义重复的脚注。
2. **首页**：状态区、主操作、设置列表结构不变；页脚右侧“仍需 Hammerspoon 兼容组件 / 原生本地翻译”只在存在旧组件时显示前者；“兼容快捷键可能仍在运行”提示同样条件显示。
3. **诊断与帮助**：拆成三段——「状态与修复」（重新检查、重新启用、辅助功能设置、准备语言包、停止云端组件）、「设置」（登录项开关、翻译方式测试、重新运行设置）、底部一个「支持范围与隐私」链接打开 `SupportInfoView`，删除内嵌的 DisclosureGroup 副本。
4. **重复文案**：关闭/暂停/退出说明只保留在 `SupportInfoView`「后台运行与停止」一处，引导完成页改为一句话 + 链接；隐私/支持范围只保留 `SupportInfoView` 一份，欢迎页与练习页各留一句短提示。
5. **浮窗**：不改布局；仅去掉朗读切换时的整视图重排（改为只更新按钮状态）。
6. **菜单栏**：删除 lab 项后检查分隔线与顺序，确保“状态 / 打开窗口 / 翻译方式 / 暂停/恢复 / 诊断 / 退出”六组清晰。

### 阶段三验收标准

- `OnboardingView` 行数下降且不再引用任何 Hammerspoon 文案于原生-only 分支；`test_macos_onboarding_contract.py` 同步更新并通过。
- 实机截图：首页（已就绪 / 已暂停）、首次设置三页、诊断页、支持范围页、浮窗成功态；深色模式各一张。
- 无新增字符串重复：`grep -c` 关键句（“选中英文，连按两次 Option”、“扫描件”/“扫描 PDF”、“退出句译”）各 ≤ 2 处。

## 6. 通用验收清单（每阶段）

```bash
S=<scratch>
xcodebuild -quiet -project Juyi.xcodeproj -scheme Juyi -configuration Debug   -derivedDataPath "$S/Debug"   CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build
xcodebuild -quiet -project Juyi.xcodeproj -scheme Juyi -configuration Release -derivedDataPath "$S/Release" CODE_SIGNING_ALLOWED=NO build
scripts/verify_macos_binary.sh "$S/Release/Build/Products/Release/Juyi.app/Contents/MacOS/Juyi" 15.0
scripts/build_macos_app.sh && scripts/build_apple_helper.sh /tmp/apple-translation-helper
scripts/run_swift_tests.sh
python -m pytest -q && python -m ruff check . && bash -n scripts/*.sh
```

真实双 Option 端到端（另一 App 选中 → ⌥⌥ → 浮窗）只能由人完成；验收记录须写明构建号与路径。

## 7. 风险与回退

- pbxproj 手工编辑出错 → 用 `xcodebuild -list` 与 `test_xcode_project_contract.py` 早发现；每阶段独立提交便于回退。
- 删除 lab 时误删生产符号 → 阶段一验收第 2 条的 `strings`/`otool` 检查 + 15 个生产测试。
- 契约测试改写过松 → 验收时逐个对照本文 §3.4 列表，禁止整文件 `skip`。
- 性能改动改变时序 → 阶段二只允许缓存与去重，不改任何超时/时间窗常量；相关常量以单测钉住。
