# 原生翻译 Result Lab（4D0，开发中未启用）

Result Lab 是默认关闭的 Debug 纯组件切片，用来把 4A 的纯输入、路由和
generation 契约接到原生浮窗，验证状态、键盘、复制和辅助功能。它不是新的
生产翻译链，也不表示已替换 Hammerspoon。

## 编译门与入口

只有同时定义以下四个编译条件的 Debug 构建才包含本切片：

`DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB`

默认 Debug、单 flag、缺少 RESULT_LAB 的组合以及任何 Release 都不包含
Result Lab 的类型、菜单、样例或入口。为避免“模拟、未联网”的页面与真实
开发适配器同时出现，Debug Result Lab 与
`JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER` 或
`JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER` 的混合构建会直接编译失败；Release
仍忽略全部开发 flags。

唯一入口是 App 主菜单“开发：结果界面实验室…”，并在主窗口中展示一个
sheet。打开 sheet 只展示披露，不创建 domain 请求、executor 或浮窗，也不
读取文件、Keychain、网络、选区、剪贴板现有内容或键盘正文。
浮窗可见时会检查按键的键码与修饰键，以识别关闭、显式聚焦、滚动和复制；
不会读取字符正文，也不会记录按键。

## 固定模拟边界

- Apple 固定原文：`The weather is pleasant today.`，只使用 installed readiness
  和内存 executor；不会加载或调用 Apple Translation。
- 火山固定原文：`Good tools should feel effortless.`，只使用内存中的固定
  consent、marker、fingerprint、credential 和 executor；每次运行恰好一次
  fake credential load 与一次 fake effect，不签名、不读 Keychain、不联网、
  不产生用量或费用。
- 两条路径均复用 4A 的 `NativeTranslationInputPolicy`、闭合 engine router、
  typed outcome 和 `UInt64` domain generation。请求 engine 与成功 engine 必须
  相同；没有 warning、fallback 或正文 cache。
- 固定非敏感原文和译文是 opt-in Debug 产物中的静态常量，因此会编译进对应
  Mach-O。关闭、新请求、停止和 lifecycle invalidation 会释放每次请求保留的
  input、浮窗中的可复制副本与 active state，并使旧 generation 失效。

## 展示 owner 与迟到结果

请求开始前，controller 为既有 overlay session 铸造 opaque presentation lease；
lease nonce、overlay `Int` generation 与 domain `UInt64` generation 分开验证。
Result Lab coordinator 是唯一 request owner，controller 只能 resolve 当前 lease，
不能在结果回调中创建新 session。每个 lease 最多接受一个 terminal。

Close、外部 App 点击、Escape、pause、stop、sleep、session/Space 变化、
anchor display 移除或 terminate 都会先使 owner/lease 失效，再取消 domain。
dismiss callback 与 domain invalidation 都是 exact-once；同步 dismissal 和重入新
请求也不能撤销较新的 lease。2 秒只显示“仍在模拟”，12 秒 deadline 由 owner
执行：先 invalidate domain，再在仍为当前 lease 时显示 timeout。任何迟到结果
都不能重开 panel、写剪贴板或发送 VoiceOver terminal announcement。

Result Lab sheet 与本 App 菜单属于 owner surface。本进程的 local mouse event
原样透传，不先关闭 external lease；其他 App 的 global outside click 仍关闭。
被动 panel 非 key 时，local Escape 交给 sheet（运行中第一下停止，空闲再关闭）；
显式聚焦 panel 后由 panel 处理 Escape。

## 复制、焦点与辅助功能

成功态正文保持静态不可选择。用户只能点击“复制固定译文”，或先显式聚焦
成功浮窗再按 Command-C，才会把完整固定译文写入系统剪贴板。实现不会读取
旧剪贴板；按用户动作先清空再写入一个 string item。复制会替换现有剪贴板，
其他 App 或剪贴板管理器之后可能读取并长期保留；若 AppKit 写入失败，旧内容
不能保证恢复。

sheet 的 Stop/Close 是 scroll 外的 sticky footer，正常和 200% 字体下保持可见，
FKA 顺序为运行按钮/聚焦（如有）→Stop（运行时）→Close。打开 sheet 时只把
VoiceOver 初始焦点放到标题；terminal announcement 的唯一 owner 是 overlay，
sheet 不在 terminal 时再次移动 VO 焦点或朗读全文。复制公告是独立的用户动作。
浮窗的 AX title、metadata 和复制公告都标明 Debug 固定样例、Apple/火山模拟及
对应的“未调用 Translation”或“未读密钥、未联网、不计费”边界。

## Python parity corpus

`tests/fixtures/native_translation_parity_v1.json` 是 version 1、固定非敏感、
input-only corpus。Swift CLI runner 与 Python pure adapter 读取同一 corpus，并
比较 canonical records：换行/trim、4999/5000/5001 Unicode scalars（含 emoji
和 combining mark）、CJK 0.5 边界、少于两个 alphabetic scalars、同 engine
route 以及既有 Volc V4 golden。

Python adapter 在加载 `translator.py` 前注入纯内存 `config`、Apple 与一个
硬失败/零调用计数的 Volc proxy；真实 `volc_engine.py` 只以隔离模块加载并调用
纯 `build_signed_request`。它不读取 HOME、环境配置、marker、Keychain 或 helper，
也不能进入网络 effect。未分类差异直接失败；version 1 明确记录的差异只有
legacy/unknown engine、Volc→Apple fallback、Python LRU 2000、非成功正文回显、
字符串错误分类、宽松 legacy parser 与 30 秒 transport timeout。它们不会反向
放宽 Swift 的 closed engine、0 fallback、0 cache、typed failure 和 strict parser。

## 自动验证与仍待真机门禁

自动门禁覆盖 lease/reentrancy/dismiss exact-once、double generation、typed
outcome、fake call counts、手动 clock、copy/VO late-drop、parity、静态 forbidden
API、Xcode/legacy 构建和产物 token/framework 扫描。

本切片合入仍只是 default-off 开发 GO。正式启用前必须在 macOS 15.0 与最新
15.x、arm64 与 Intel 上完成：打开 0 I/O、同一 passive panel、TextEdit/Safari
焦点与选择保持、outside/Escape 透传、Control-F6/FKA、复制、VO 一次公告、
Light/Dark/Reduce Motion/Transparency/Contrast、200% 字体、多屏/fullscreen/
Stage Manager/Space，以及 Network/Keychain 观测为 0。真实 Apple、真实火山、
真实 AX bounds、权限撤销通知接线和 live owner/lease 是后续 4D-A 独立切片；
4D0 不探测辅助功能权限，也不为此增加权限轮询。当前保留的 typed revoke policy
与纯测试只是未来接缝，不宣称已有 live revoke 事件来源。
