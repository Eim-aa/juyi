# 原生火山翻译适配器（4C，默认关闭）

状态：**仅供开发验证；生产启用仍是 NO-GO。** 这组代码不会替换现有 Python 后端或 Hammerspoon 双 Option 翻译链，也不会修改当前引擎、`volc.env`、LaunchAgent、辅助功能监听、选区读取或原生浮窗。

## 编译门和唯一入口

实现、Security/LocalAuthentication 导入、App sheet 接线和主菜单入口都完整位于同一个编译门内：

```swift
#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
```

默认 xcconfig 与 Release 不定义此开关。只有开发者显式注入 domain 与 4C 两个条件的 Debug 构建才包含主菜单项“开发：测试火山云端翻译…”。打开 sheet 本身不会读取钥匙串、文件或发起网络请求；用户必须先阅读披露，再明确点击检查、验证或测试操作。

页面明确说明 AK 账号标识会随签名请求发送、SK 本体不会发送，并且火山服务会获得用户的 IP 地址和正常连接元数据；不会用笼统的“必要元数据”替代这一披露。

固定非敏感样例精确为 `Good tools should feel effortless.`，源语言固定 `en`，目标固定 `zh`。这是本切片唯一允许发送的正文。每次显式验证或测试最多发起一次真实 HTTPS 请求，可能产生少量 API 用量或费用；没有自动重试、自动 fallback 或后台预热。

同一句固定样例在 4C 之前已经被旧 onboarding 与生产云验证使用，因此产物门禁只把它作为 opt-in 的正向检查，不能把它误当成 4C 独占的负向 canary。default Debug、domain-only、Apple-only 与 Release 的关闭证明改为扫描 4C 独有 sentinel、Debug service/目录、Workflow/Host 类型、开发披露、菜单和 Security/LocalAuthentication load；不会为了迁就测试去改动既有生产字符串或行为。

文件边界固定如下，便于 Xcode、legacy 脚本、CI 与静态契约逐项核对：

- `NativeVolcDebugCredentialStore.swift`：独立 Debug Keychain 四槽、fingerprint 与 promotion journal；
- `NativeVolcDebugInterlock.swift`：私有目录、stable locks、intent/marker 与 revocation epoch；
- `NativeVolcDebugTransport.swift`：固定 request sink、ephemeral URLSession 与流式响应上限；
- `NativeVolcDebugWorkflow.swift`：single-flight、generation、验证/晋升/回滚/移除编排；
- `NativeVolcTranslationAdapterModel.swift`：纯 phase/action UI 状态、手动时钟和迟到结果门；
- `NativeVolcTranslationAdapterHost.swift`：唯一 Debug sheet、披露、SecureField 与显式操作。

## 独立 Debug 凭据和可恢复事务

4C 使用真实 macOS Keychain API，但只使用四个独立 Debug service：active、pending、verified 和 transaction。它们都带 `io.github.Eim-aa.Juyi.debug.native-volc` 前缀；不会读取或改写生产 Keychain、生产删除标记、UserDefaults、配置文件或运行服务。

AK/SK 先经过 4A 的本地格式约束，再写入 pending。只有固定样例验证成功后，才在独占 promotion lease 内落 durable transaction journal，并按 active、verified、pending、journal 的可读回确认推进。journal 包含旧 active/verified 的备份和闭合 phase；前向提交和回滚 phase 都可在进程重建后幂等恢复，恢复不确定时保留 journal 并 fail closed，不会再发一次网络请求。

合法 pending 且没有 journal 会显示独立的“继续验证”与“仅放弃候选”操作。继续验证再次明确提示真实调用和可能费用；放弃候选不会删除旧 active。打开 App 或 sheet 不会自动恢复、删除或联网。

Keychain query 固定 `synchronizable=false`。当前 ad-hoc/空 entitlement 工程继续使用传统 login Keychain，不启用 Data Protection Keychain，也不设置仅适用于其语义的 accessible 属性。为避免后台请求触发认证 UI，传统 Keychain query 以 `kSecUseAuthenticationUI` 的运行时值 `u_AuthUIF` 作为权威 fail-without-UI 门；每次 query 同时附加一个 `interactionNotAllowed` 的 `LAContext` 作为补充防线。后者在当前运行时无法通过 getter 可靠自证，因此自动测试不会把它夸大为已验证的双保险；`u_AuthUIF` 字面值是需要在未来签名/Keychain 迁移时清理的技术债。

显式“检查 Debug 配置”同样先取得 reader gate 与 transport lease，并在任何 Keychain 读取前、四槽快照读取后各复核一次 intent、marker 与 revocation epoch。writer intent 已出现或控制状态不可确认时会在 0 Keychain、0 network 下返回阻断/暂时不可用；检查持有的 lease 释放前，移除 writer 不能开始删除槽位。

## 删除互锁与撤权

独立 Debug 目录位于 `~/Library/Application Support/io.github.Eim-aa.Juyi/NativeVolcDebug/`。目录和控制文件分别限制为 0700/0600，并拒绝符号链接、异常 owner、非 regular 文件、路径与 fd inode 不一致、短 I/O 和未持久化的目录变化。

网络 reader 使用两把稳定锁：request gate 与 transport lease；移除 writer 另持一把永不 unlink 的 owner lock。reader 先捕获 durable revocation epoch，再检查 writer intent，取得共享 gate/transport，复核 intent、marker、epoch、Keychain 与 verified fingerprint，签名后在 `resume()` 前最后复核；resume 后释放 gate，但 transport lease 保持到 URLSession completion 和内存清理。已验证 active 的测试响应在发布前还会重新取得 reader lease，核对原 revocation epoch、active、verified、journal 及 interlock；若另一进程已先完成移除，旧响应只会进入“状态尚未确认”并要求显式检查，绝不会显示成功或自动重试。

移除先在内存推进 generation 并请求取消，再以 O_EXCL 创建、fsync writer intent，取得独占 gate 后落 removal marker 作为 commit 点；随后等待本进程 completion 释放共享 transport lease，再取得独占 transport。删除顺序固定为 verified → active → pending → transaction，逐槽确认 absent 后原子轮换 revocation epoch，最后才清 marker 与 intent。owner lock、epoch 与 operation token 一起防止并发 writer、旧 save 在移除后 ABA 复活，或崩溃恢复 waiter 重删新配置。任一步不确定都会保留 fail-closed 状态。

## 固定网络边界

transport 只接受 4A builder 为固定样例生成的精确请求：

`POST https://translate.volcengineapi.com/?Action=TranslateText&Version=2020-06-01`

请求正文必须逐字节等于固定 deterministic body；header 名集合、Host、X-Date、payload hash 和 Authorization grammar 都要通过 sink 端校验。它使用每 generation 一个 ephemeral URLSession，显式关闭 URL cache、cookie storage、credential storage、additional headers 和 waits-for-connectivity。所有 redirect 都拒绝；task-level 与 session-level challenge 都只允许固定 HTTPS host/443 的 server-trust 默认处理，其他认证方式取消，不实现自定义 trust 或 client credential。

响应通过 delegate 流式累积，声明长度或实际数据超过 1 MiB 都立即取消并映射为 transport-security failure。单次 request timeout 为 10 秒，UI generation 为 12 秒，2 秒显示慢连接提示；没有 retry。取消会立即使 UI generation 失效，但锁只在 URLSession completion 后释放，避免移除与仍在飞行的请求竞态。

parser 只接受恰好一个 legacy 顶层 `TranslationList` 或恰好一个官方 `Result.TranslationList`；两者同时出现、零条、多条、空译文、错误类型或超大正文都 fail closed。typed 错误不携带 HTTP body、上游 code/message、原文、译文或凭据；日志也不记录这些内容。

## UI 与隐私边界

sheet 明确说明它连接真实 API，不是模拟器；除用户在表单主动输入的 AK/SK 外，不采集键盘内容，也不读取翻译选区或剪贴板。AK 与 SK 都保存在独立 Debug Keychain；AK 账号标识会随 Authorization 发送，SK 只在本机派生签名，SK 本身不发送、不进入请求正文或日志。字段不会自动回填，关闭、新 generation、暂停、停止、引擎变化、移除、休眠、会话退出和 App 终止都会清除表单与当前译文。

“停止等待”或 12 秒 UI timeout 不能证明请求未发送，所以 network context 始终提示：请求可能已发送、可能产生少量用量或费用、迟到译文不会显示或保存，配置状态需要用户显式复查。检查配置和移除等零网络操作使用独立文案。移除成功显示独立终态，不自动把焦点送回 AK 输入框。

## 自动验证与真机门禁

CI 的 Keychain、锁和 transport 测试全部使用 fake client、临时目录或 URLProtocol，不访问真实 Keychain 或火山网络。自动化覆盖：

- Debug-only 三重编译门与 default Debug/domain-only/Apple-only/Release 产物扫描；
- Keychain 状态映射、redaction、write/readback 和事务崩溃 cutpoint；
- 多进程锁、intent/marker、owner、epoch、symlink/mode/inode、ABA 和取消竞态；
- 固定 request、redirect/TLS challenge、1 MiB 上限、timeout/cancel 与 lease exact-once；
- workflow single-flight、generation、pending 恢复、promotion/rollback、remove 顺序；
- model action allowlist、手动时钟、迟到结果丢弃、费用披露和打开零 I/O。

正式考虑启用前仍必须完成真机 P0：macOS 15.0 与最新 15.x、arm64 与 Intel、登录钥匙串解锁/锁定、ACL 需要确认/拒绝、屏幕锁定、睡眠/唤醒、进程崩溃恢复、真实火山 endpoint 的 redirect/TLS/慢网/取消/1 MiB 行为。必须证明锁定或 ACL 状态下没有隐式对话框、没有网络、没有槽变更；解锁后只由显式 retry 继续，并确认 Debug item 不经 iCloud 同步。当前开发机上的 Xcode 26 编译、fake Keychain 与 URLProtocol 不能替代这些真机验证。
