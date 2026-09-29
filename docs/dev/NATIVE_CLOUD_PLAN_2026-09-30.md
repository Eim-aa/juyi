# 火山云端原生化计划 · 2026-09-30

前提：用户确认云端翻译必须保留（长难句需要更好的模型）。目标是**保留火山翻译功能，删除为它而存在的整套外部运输层**（Python 服务、LaunchAgent、本地 token、Hammerspoon Lua、helper CLI、owner 交接），让云端与本地共用同一条原生链：双 Option → 取词 → 翻译 → 浮窗 → 朗读。

基线：`main` `0e3219c`（build 17）。分支 `claude/native-cloud`。

## 1. 现状

- 选 Apple：原生 App 独立完成全链。选火山：`setAppleEngineSelected(false)` 关掉原生链，改由 Hammerspoon Lua 监听按键、取词、POST 到 `127.0.0.1:54321`，Python 签名调火山，Lua 用 `hs.canvas` 画另一个浮窗。
- Release 二进制里没有任何火山客户端。第一阶段删除的 lab 文件里有经过单测的 V4 签名器与响应解析器（`git show c7ecf24^:macos/VolcV4RequestBuilder.swift`、`VolcTranslationResponseParser.swift` 及对应 tests），可作为起点。
- 为运输层存在的代码：`JuyiMenuBar.swift` 约 630 行云端事务协调 + 约 700 行服务/Hammerspoon 逻辑；`NativeOptionFeature.swift` 约 350–400 行 owner 交接；owner 交接 5 个文件 1 255 行 + 测试 1 122 行；Lua 1 066 行 + 测试 762 行；Python 5 个文件约 1 180 行 + 测试约 1 000 行；脚本约 1 600 行。
- 浮窗模型已预留 `.volc` 引擎、`volcCredential/volcNetwork/volcTimeout/httpFailure/malformedResponse/emptyResult` 错误与 `checkCloudSettings` CTA，生产代码尚未发出。

## 2. 原则

1. 用户可见行为：火山模式与本地模式**完全相同的手势、取词、浮窗与朗读**，只是译文来源与浮窗元数据（“火山云端 · N 毫秒”）不同。Apple 失败不自动转云端，火山失败不自动转本地。
2. 密钥只在钥匙串（服务名 `io.github.Eim-aa.juyi.volc`、账户 `volc`、JSON 负载不变），读写继续走现有 `/usr/bin/security` 封装（不引入 `Security.framework`，CI 装载断言不变）。密钥不进日志、不进 UserDefaults、不进任何文件。
3. 请求只在翻译时发出；验证密钥时发一句固定英文；不做预热请求。
4. 4A 完成后旧栈仍在仓库但原生 App 不再调用；4B 才删除。两阶段各自可构建、可验收。
5. 禁止事项同前：不碰 `scripts/start_service.command` 与 `tmp/`；不改 bundle id、签名、版本号；不新增编译开关。

## 3. 阶段 4A：原生火山引擎

### 3.1 新文件

- `macos/VolcV4RequestBuilder.swift`：从 `c7ecf24^` 恢复，去掉 lab 依赖（`NativeTranslationFailure` 等域类型），API 保持 `build(credentials:text:source:target:now:) throws -> VolcV4SignedRequest`（url、headers、body）。Host `translate.volcengineapi.com`，`Action=TranslateText&Version=2020-06-01`，Region `cn-north-1`，Service `translate`，body `{"SourceLanguage":"en","TargetLanguage":"zh","TextList":[text]}`。
- `macos/VolcTranslationResponseParser.swift`：恢复并把结果类型改为 `Result<String, VolcTranslationError>`。
- `macos/VolcTranslationEngine.swift`（新，约 150 行）：`final class VolcTranslationEngine`，`func translate(_ text: String) async -> VolcTranslationOutcome`，`func validate(credentials:) async -> VolcTranslationOutcome`。使用注入的 `URLSession`（默认 `ephemeral`，`waitsForConnectivity = false`，请求超时 12 s 与 `translationTimeout` 一致），读取钥匙串凭据（通过 AppModel 已有的离主线程读取封装或等价的 `nonisolated` 静态函数），映射错误：
  - 无凭据 / 火山返回鉴权错误码 → `.volcCredential`
  - `URLError` 网络类 → `.volcNetwork`；超时 → `.volcTimeout`
  - 非 2xx 且非鉴权 → `.httpFailure`
  - JSON 解析失败 → `.malformedResponse`；`TranslationList` 为空或译文为空 → `.emptyResult`
  - 支持 `cancelCurrent()`（取消在途 `URLSessionTask`）。
- `tests/VolcV4RequestBuilderTests.swift`、`tests/VolcTranslationResponseParserTests.swift`：从历史恢复并适配；`tests/VolcTranslationEngineTests.swift`：用 `URLProtocol` 桩验证错误映射、取消与超时。把 `tests/test_volc_signing.py` 里的签名向量搬进 Swift 测试。三者加入 `scripts/run_swift_tests.sh`、pbxproj、`build_macos_app.sh`。

### 3.2 协调器（`NativeOptionFeature.swift`）

- 新增 `enum NativeTranslationEngineChoice { case apple, volc }` 与 `func setEngine(_:)`，替换 `setAppleEngineSelected(_:)`：切换引擎**不再关闭原生链**；只在 volc 时跳过 Apple 就绪预检（`NativeTriggerPreflight` 增加引擎维度或在 `beginPipeline` 分支）。
- `receiveCapture`：按引擎分发。volc → `VolcTranslationEngine.translate`，成功则 `NativeTranslationOverlayResponse(requestedEngine: .volc, actualEngine: .volc, …)`，失败映射到上述错误；超时路径对 volc 发 `.volcTimeout` 并 `cancelCurrent()`。
- `enable()` 的语言包就绪检查只在 apple 引擎下作为启用条件；volc 引擎启用条件是“钥匙串里有凭据”（缺凭据时 phase 走现有 `.unavailable` 并给出“请配置火山密钥”detail，浮窗 CTA `checkCloudSettings`）。
- 引擎切换时取消在途翻译，浮窗按现有 generation 规则丢弃迟到结果。

### 3.3 AppModel 与界面（`JuyiMenuBar.swift`）

- `setEngine(_:)`：写 UserDefaults `selectedEngine`（新的唯一来源），同时**暂时**继续写 `hs-engine` 与 `volc.env` 的 `ENGINE=`（4B 删除），调用协调器 `setEngine`。启动时读取顺序：UserDefaults → 旧 `hs-engine`（迁移一次）。
- `configureCloud`：候选凭据在内存中用 `VolcTranslationEngine.validate` 直接验证 → 成功后 `saveKeychainCloudCredentials` → `setEngine("volc")`。删除 pending 钥匙串项、`validatePendingCloud`、`startServiceAndWait`、`waitForService`、`recoverInterruptedCloudConfiguration`。
- `validateExistingCloud`：读钥匙串 → `validate`。`removeCloud`：确认后删除钥匙串项 → `setEngine("apple")`；删除 removal-marker 机制与 `restoreCloudRemoval`/`finishInterruptedCloudRemoval`。
- `testTranslation`：volc 分支改为原生引擎。
- `readLocalState` 不再因 `hs-engine` 变化关闭原生链；`refresh()` 的 `/health` 探测在 4A 保持但 `shouldProbeService` 去掉 `selectedEngine != "apple"` 条件（云端不再需要服务）。
- 云端设置页文案：去掉“需另装后台组件”，改为“需联网并配置火山密钥；选中的英文会发送至火山”。首页“翻译方式”与菜单栏引擎子菜单在两种引擎下都保持原生链启用状态显示。
- 诊断页“测试当前翻译方式”对 volc 走原生引擎；“停止云端翻译组件 / 修复云端组件 / 打开安装说明”按钮 4A 保留（4B 删）。

### 3.4 契约测试

- `test_macos_security_contract.py`：pending 项、removal marker、`validate/volc-pending`、服务重启相关断言改为断言其**不存在**；保留 `runSecurity` 封装、密钥不进日志、`DispatchSemaphore` 只在 `runBoundedProcess` 内。新增：`VolcTranslationEngine` 不写 UserDefaults/文件，`URLSession` 请求头不含明文 SK（签名器只输出签名）。
- `test_native_option_monitor_contract.py`、`test_native_translation_overlay_contract.py`：更新对 `setAppleEngineSelected` 与 `.volc` 未使用的断言。
- 新增 `tests/test_native_volc_engine_contract.py`：三个新源文件在 pbxproj / `build_macos_app.sh` / runner 中；`translate.volcengineapi.com` 只出现在 builder；`SourceLanguage` 为 `en`。

### 3.5 4A 验收

- 全部构建与测试检查（同前一轮 `accept.sh`）通过；Release 二进制 `strings` 含 `translate.volcengineapi.com`，`otool -L` 仍不含 `Security.framework`。
- 人工（用户）：在云端设置页输入真实 AK/SK → “保存并验证”成功；切到火山后在文本编辑选中英文 ⌥⌥，原生浮窗显示译文且元数据为“火山云端 · N 毫秒”；朗读可用；断网后再试显示网络错误且不改用 Apple；切回 Apple 正常；诊断页测试翻译成功。全程 Hammerspoon 与 Python 服务不存在。

## 4. 阶段 4B：删除运输层

- 删除：`server.py`、`translator.py`、`config.py`、`apple_engine.py`、`volc_engine.py`、`requirements.txt`、`eval/`、`apple/TranslationHelper.swift` 与 `AppleTranslationHelper` target、`launchd/`、`hammerspoon/`、`scripts/{install,bootstrap,launchd_install,launchd_uninstall,ensure_auth_token,hammerspoon_hook,build_apple_helper,smoke.py,test_matrix.py,test.sh}`；`uninstall.sh` 改写为仅处理登录项、App 与钥匙串（保留“是否删除火山密钥”询问）并清理旧 `~/.config/argos-translator` 与 Hammerspoon 托管块。
- Swift：删除 `NativeOwnerHandoff{Protocol,Store,Workflow,StatusReader}.swift`、`NativeOwnerActivationCoordinator.swift` 及其测试；`NativeOptionFeature.swift` 去掉交接、`waitingForHammerspoon`、`legacyRecoveryPauseHandler`、workspace 观察；`NativeTriggerPreflight` 只剩就绪缓存。新增 `macos/LegacyComponentCleanup.swift`（约 120 行）：启动与启用前检测 `~/.hammerspoon/argos-translator.lua` 符号链接、`init.lua` 托管块、`~/.config/argos-translator/{hs-status.json,owner-request.json,native-owner.lock,auth-token,volc.env,hs-engine}` 与 LaunchAgent plist；检测到则在首页/引导显示“检测到早期组件”并提供一键移除（只删自有符号链接与托管块、bootout 并删除 LaunchAgent、删除上述文件；不动用户其它 Hammerspoon 配置），移除前**不启用**原生链（fail-closed 替代原交接）。`hs-paused` 改名为 UserDefaults 暂停状态并迁移。
- `JuyiMenuBar.swift`：删除 §3 报告中列出的服务/Hammerspoon 代码（`Health`、`HotkeyStatus`、`hotkeyProblem`、`refresh` 的 HTTP、`repairService`、`stopService*`、`installBundledShortcut`、`restartHammerspoonAfterInstall`、`runHammerspoonHook`、Lua 资源打包、诊断页三个按钮、日志按钮改为打开 `~/Library/Logs/` 下的 App 日志或删除）。保留登录项 LaunchAgent 回退（与 Hammerspoon 无关）。
- 测试：删除 `test_config_env/engine_resolution/error_classification/input_policy/server_auth/volc_signing/hammerspoon_reliability_contract/native_owner_handoff_contract/install_security.py` 与 `hammerspoon_runtime_test.lua`；`conftest.py` 去掉 security 桩；改写 `test_macos_security_contract`、`test_macos_onboarding_contract`、`test_macos_install_contract`、`test_native_option_monitor_contract`、`test_native_apple_translation_adapter_contract`、`test_xcode_project_contract`（helper target、`baseConfigurationReference` 计数变为 2）。新增 `tests/test_legacy_cleanup_contract.py` 与 `tests/LegacyComponentCleanupTests.swift`。
- CI：`python` job 只跑契约测试（`requirements-dev.txt` 保留 pytest/ruff）；`syntax` job 去掉 Lua；`swift` job 去掉 helper 构建与 `NativeOwnerActivationCoordinator`/`native-owner.lock`/`owner-request.json` token 断言，改为断言 `VolcTranslationEngine` 与 `translate.volcengineapi.com` 存在。
- 文档：`README.md`/`README_EN.md` 云端一节改为“填入火山密钥即可”；`AGENTS.md` 重写为“下载 DMG → 授权 → 可选填火山密钥”，删除 Step 1/2/5b/6 的源码安装与服务验证；`docs/MENU_BAR_APP.md` 安装、翻译方式、菜单栏、开发与发布；`docs/BUILD.md` 仓库结构表；`docs/RELEASE_BASELINE.md`；`docs/README.md`；`docs/dev/NATIVE_*` 顶部历史说明补充“Hammerspoon 交接已于 2026-09-30 移除”。

### 4B 验收

- 仓库不再含 `54321`、`argos-translator.lua`、`hs-status.json`、`owner-request.json`（文档历史记录除外）；`grep -rn 'Hammerspoon' macos/` 只剩 `LegacyComponentCleanup.swift`。
- 全部构建/测试检查通过；`macos/` 预计约 9 500 行；仓库净减约 7 000–8 000 行。
- 人工：本机（无旧组件）启动后首页不出现“早期组件”提示；模拟旧组件（创建 `~/.hammerspoon/init.lua` 托管块与符号链接）后出现提示，一键移除后可启用；火山与 Apple 各翻译一次。

## 5. 后续（不在本计划内）

- 长难句自动走云端：按词数或句长阈值选择引擎，用户可开关；需要先确定阈值与失败回退策略。
- 拆分 `JuyiMenuBar.swift`（AppModel 按登录项、云端、状态三块拆文件）。
