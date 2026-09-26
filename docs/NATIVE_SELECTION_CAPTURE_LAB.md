# 原生一次性取词实验室（4D-B，开发中未启用）

4D-B 是默认关闭的 Debug-only、capture-only 实验切片。它只验证一次显式的
原生 AX 取词、敏感文字生命周期和权限交互，不接翻译、浮窗或生产热键。
Hammerspoon 仍是生产双 Option 的唯一 owner；本切片不接管、不暂停，也不与其
交换 lease。

## Exact 编译门与入口

本切片只存在于精确满足以下条件的构建：

`DEBUG && JUYI_NATIVE_SELECTION_CAPTURE_LAB`

它不得与下列任一条件混合：

- `JUYI_NATIVE_OPTION_MONITOR`
- `JUYI_NATIVE_TRANSLATION_DOMAIN`
- `JUYI_NATIVE_TRANSLATION_OVERLAY`
- `JUYI_NATIVE_TRANSLATION_RESULT_LAB`
- `JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER`
- `JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER`
- `JUYI_NATIVE_APPLE_RESULT_LAB_BINDING`

Debug 混入任一条件都会由源码 `#error` fail closed。普通 Debug、只缺 Lab flag，
以及仓库支持的 Release 配置与 legacy Release 脚本都不包含 Lab 类型、sentinel、
菜单或文案；即使向这些 Release 路径注入全部自定义开发 flags（不伪造 `DEBUG`），
也必须得到空的 4D-B 产物。

唯一入口是 App 主菜单“开发：原生取词实验室…”，打开主窗口中的“一次性取词
实验室”sheet。未暂停时打开只做一次只读授权状态检查；暂停时打开为 0 次状态
读取并只显示 paused。两者都不触发 TCC prompt、不读取前台 App、不启动倒计时，
也不执行 AX 取词。

## 显式权限与手动 5 秒切换

只有用户点击“请求辅助功能权限…”才调用 macOS 的显式权限请求；macOS 是否
允许完全由用户决定，代码不能代为授予。点击“重新检查权限”只读取当前状态，
不会请求权限。此处授予的是句译进程本次实验所需的 AX 能力，不替代、移交或
接管 Hammerspoon 的生产 owner，也不代表原生热键已获准上线。

用户点击“开始一次取词演练（5 秒）”后，句译不会自动激活、隐藏或切换目标
App。用户须在 5 秒内手动切回目标 App 并保持文字选中。倒计时期间不轮询目标；
截止点 owner 只形成一次不可变目标快照。reader 随后会在 AX 读取前后做两次
identity-only 的前台进程复核，但不会用复核结果替换该快照，也不会因此多读正文。
目标必须是未终止的 regular App、不是句译自身，并具有正 PID、
非空 bundle identifier 与 `PID + NSRunningApplication.launchDate` 完整进程身份。
bundle identifier 是必填准入元数据，真正的同进程判断仍使用 PID 与 launchDate，
避免 PID 重用。

同一个 `NativeSelectionTarget` 快照会原样传给 capture coordinator 和 reader，
不会从 PID 重建。reader 在 AX 读取前后重新核对前台完整进程身份，并在读取文字
前后复验 focused element 身份、PID、role/subrole；未知、缺失、非字符串、安全
或未审核控件均 fail closed。当前只允许已审核的
`AXTextField + AXSearchField` 组合，兼容性不能通过放宽 unknown subrole 获得。

## Capture-only 与隐私边界

“零调用”只描述 4D-B 的一次实验动作和本切片代码，不代表句译主 App 的既有
后台健康检查停止。4D-B 自身不会监听双 Option，不会调用 Apple Translation、
Volc、localhost、本机翻译 Domain、overlay 或 Keychain；不会读取或写入系统
剪贴板，不提供 Copy，不记录正文，也不把正文写入文件、UserDefaults、日志或
任何持久化介质。它不创建翻译请求、网络请求、用量或费用。

AX 成功结果最多保留 5,000 个 Unicode scalars，只在 sheet 的不可选择静态正文中
显示。macOS 辅助功能可以读取窗口中的文字。正常运行时结果收到后 30 秒自动
清除；若进程或主线程暂停，会在恢复调度的最早时机通过单调 deadline 复核清除。用户
“立即清除”、关闭、暂停、停止、系统睡眠、会话退出、辅助功能权限撤销或 App
终止会立即使旧代次失效，并清除窗口与 owner 状态可达的文字，再调用外部
cancel。已经进入系统同步 AX 的读取不能物理中断，正在收尾的系统读取及其临时
对象可能在运行时内存中短暂存在；返回后的迟到结果为 0 显示、0 保存，任何同步
重入或迟到 completion 都不能恢复旧文字。

引用释放不是安全擦除：Swift/macOS 不保证物理覆写已释放内存。若用户在其他
工具中截屏、朗读、采集进程内存或以辅助功能读取窗口，相关副本不受 4D-B 的
30 秒 TTL 控制。

## 暂停、生命周期与 VoiceOver

暂停是持久 owner 状态：暂停期间重新打开 sheet 仍必须是 paused，不能被 `open()`
重置为可运行；暂停中 reopen 或 App 再次激活都不查询授权状态，保持 0 TCC 读取。
恢复后只回到 idle，绝不自动开始。Close、pause、stop、sleep、session resigned、
accessibility revoked 和 terminate 都先 tombstone 当前 generation，再取消倒计时、
TTL 或正在进行的 capture。已进入同步 AX 的调用不能物理中断，但返回值会因
generation 不匹配而被丢弃。

取词完成时如果用户仍在目标 App，句译不会激活自身、移动其他 App 的焦点或在
目标 App 中播报正文。sheet 首次打开时只把辅助功能焦点放到标题一次；之后用户
手动回到句译时，VoiceOver 最多收到一次固定短反馈“取词演练状态已更新，请返回
句译查看。”。反馈不含选中文字，后台完成不会强制把焦点拉到结果或朗读正文。

## 自动门禁与 GO / NO-GO

自动化 GO 只表示这个 default-off 开发切片可提交：

- 纯 Swift 测试在 `-swift-version 5 -warnings-as-errors` 下覆盖 5 秒手动 clock、
  单次 target/capture、完整 process identity、30 秒 TTL、权限动作、close/pause/
  stop/sleep/session/revoke/terminate 清理、同步重入与迟到结果 0 副作用；
- Xcode 与 legacy 都构建 exact Debug 正向组合，并逐一验证七个冲突条件必然失败；
- Xcode 与 legacy 的 Release 全 flags 构建必须为空；
- 对整个 `Juyi.app/Contents/MacOS` 做 raw byte grep：exact Debug 必须包含 4D-B
  sentinel、类型和菜单，默认 Debug/Release 必须全部缺席。负 canary 只使用
  4D-B 自己的 token，不把 4A 中合法的 Volc endpoint、builder 或 parser 当作
  “4D-B 未混入”的证据。

自动化 GO 不是实机授权、兼容性或生产 Activation GO。

真机 P0 必须在 macOS 15.0 与最新 15.x、arm64 与 Intel 上完成：干净 TCC 的
未授权打开、显式请求/拒绝/允许/重新检查；5 秒内手动切换、截止瞬间切换 race、
目标退出与 PID 重用；已审核控件的成功/无选区/secure/unknown fail closed；
30 秒与全部提前清理；暂停中 reopen；同步 AX 迟到；VoiceOver 只在返回句译后
一次固定反馈；Network、localhost、Keychain、剪贴板、日志和翻译调用的 4D-B
增量观测均为 0。

P1 覆盖 FKA、200% 字体、Reduce Motion/Transparency/Contrast、Light/Dark、
多屏、fullscreen、Stage Manager、Space、sleep/wake 及长文本可读性。P1 不得
放宽 P0 的进程身份、role/subrole、TTL 或 owner 边界。

生产 Activation NO-GO；双 Option NO-GO；真实 Apple、真实 Volc、Domain 与
overlay 接线 NO-GO；Hammerspoon→原生 owner/epoch handoff NO-GO。任何 production
owner 迁移都必须在后续独立切片中设计原子 pause/lease/TCC/lifecycle 协议并完成
真机 GO，不能由 4D-B 的 capture-only 自动证据推导。
