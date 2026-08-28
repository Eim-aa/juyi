# 真实 Apple 结果实验室绑定（4D-A，开发中未启用）

4D-A 用一个固定、非敏感样例把 4A domain、原生浮窗与 macOS 15
`Translation` 的真实 session 接起来。它只验证真实 Apple 结果的 owner、展示、
取消和辅助功能边界，不替换当前 Hammerspoon/Python 生产链，也不读取生产选区。

## Exact 编译门

本切片只存在于同时定义以下六个条件的 Debug 构建：

`DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING`

唯一入口是 App 主菜单“开发：真实 Apple 结果实验室…”。这个组合会编译排除
4B 的独立适配器 UI、4D0 模拟 Result Lab 和旧 overlay fixture preview。缺任一前置
条件、四门 Result Lab 加 Apple 但没有 binding、或再混入真实 Volc adapter 的 Debug
构建都会 fail closed；Release 忽略全部开发 flags。默认 Debug/Release 不包含 binding
sentinel、类型、菜单、固定样例或 `Translation` framework load。

## 固定输入与真实处理

- 原文精确为 `The weather is pleasant today.`，源语言 `en`，目标语言
  `zh-Hans`。目标译文由真实 Apple Translation 返回，因此不是固定字符串。
- 打开 sheet 恰好查询一次 availability；不会取得展示 lease、创建 4A 请求、
  创建 session、准备语言包或翻译。
- `supported` 只允许用户显式点击准备。Stop 或 Close 只停止句译等待，macOS
  的系统下载可能继续；准备结束后必须重新查询，不会自动翻译。
- 翻译从用户点击并成功预留 dormant lease 起使用同一个 12 秒总 deadline；fresh
  availability、4A domain、SwiftUI host acquisition 和真实 translate 全部计入，
  任何阶段都不重置时钟。host acquisition 另有 5 秒 fail-closed 门。
- 本切片不会读取真实选区、剪贴板现有内容、键盘字符正文、Keychain 或火山云端
  配置；不调用 Volc，不签名，不产生 Volc 用量或费用。准备语言包可能由 macOS
  联网。固定正文会交给 Apple Translation 在本机处理；Apple 可能处理 App 标识、
  语言对及不含正文的使用和性能信息。

## 单 owner、host receipt 与展示 lease

`NativeTranslationAppleResultLabCoordinator` 是唯一请求 owner。它先预留 dormant
opaque presentation lease；fresh availability 不是 `installed` 时只更新 sheet，
零 panel、零 overlay terminal 公告、零 session，sheet 仅提供一次状态反馈。4A 请求
开始后，SwiftUI keyed child host 为每个
`ownerGeneration + requestGeneration` 保存独立 Configuration 和不可变 request。
旧 child 即使迟到进入 `.translationTask`，也只能尝试领取旧 request，不能读取或
claim 新 request。

host 对当前 request exact-once claim 成功后才由私有 authority 铸造 opaque receipt，
激活同一 lease 的真实 Apple loading，再调用物理 `translate`。live bridge 同时验证
fixture、真实 provenance、requested engine、4A generation、lease、receipt、非截断
输入、非负且不超过 12 秒的耗时，以及有限且无禁用控制字符的可变输出。未知、
stale、重复、mismatch 和无 receipt 的 outcome 均 fail closed，不能展示正文或复制。

Stop、Close、新请求、pause、engine/服务变化、sleep、session/Space/display 变化、
terminate 与已授权→未授权的前台检测都会先 tombstone owner/host claim，再清物理
Configuration、domain 和 lease。撤销回调和 domain invalidation 均 exact-once；迟到
availability、prepare、host、domain 或动画结果不能重开 panel、复制或播报。

## 浮窗、复制与 VoiceOver

真实结果继续复用同一个 passive overlay controller，但 lease identity 固定为
`realAppleFixed`；窗口标题、loading、Copy、Close 和公告都不会出现“模拟”。真实
host claim 激活时播一次简短 loading 公告，首次 2 秒 slow update 再播一次；重复、
stale 或已 dismiss 的 update 为零公告。terminal announcement 的唯一 owner 是
overlay。若 terminal 在展示前被拒，sheet 只对非可见 safety 状态提供一次反馈。

成功后只有用户点击“复制 Apple 译文”或显式聚焦浮窗再按 Command-C 才写系统
剪贴板。实现不读取旧内容；写入会替换当前内容，其他 App/剪贴板管理器之后可能
继续保留译文。写入失败也不尝试读取或恢复旧内容，并播报“系统剪贴板内容可能已
改变”。关闭前未复制的译文只保留在当前请求/浮窗状态；复制后的副本不受句译控制。

固定样例不要求辅助功能授权，也不会请求或弹出辅助功能授权提示。冷启动已未授权仍允许显式运行。
只有句译此前看到已授权、随后再次成为前台并检测到运行中授权被
撤销时，才撤销当时 owner；它不是实时权限监听。撤销后 fresh reopen 仍可运行。

## 自动证据与 Activation 门禁

纯 Swift 测试覆盖 availability/prepare/host/12 秒边界、keyed stale slot、同步清理
重入、dormant lease、receipt、variable result bridge、typed failure、copy/VO、
resolve rejection、late-drop 和 exact-once cleanup。静态及 Xcode/legacy 构建门检查
六门正向、逐缺前置与 mixed-Volc 拒绝、Release 注入隔离、Universal 2/minimum
macOS 15、唯一菜单/token，以及 `Translation` 与 `_Translation_SwiftUI` 正向 load；
同时负扫 4B、4D0、旧 overlay preview、4C、Security 和 LocalAuthentication 产物。

这些自动证据不是 Activation GO。正式启用前仍须在 macOS 15.0 与最新 15.x、
arm64 与 Intel 上验证：installed/needs-preparation/unsupported/temporary 状态，系统
下载确认/拒绝/断网/低空间，pack removal race，Stop/Close/sleep/session/Space/
display/terminate，冷启动未授权与运行中前台撤权，passive panel、FKA、VoiceOver
loading/slow/terminal 各一次、Copy 成功/失败，以及 Network/Keychain 观测。除用户
显式准备语言包可能触发 macOS 下载外，必须观察到零 Volc 网络和零 Keychain 访问。
