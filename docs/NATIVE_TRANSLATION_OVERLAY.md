# 原生译文浮窗：纯组件预览

状态：**仅供开发验证，默认未启用，不是当前用户功能。**

只有同时满足 `DEBUG` 和 `JUYI_NATIVE_TRANSLATION_OVERLAY` 两个编译条件时，句译 App 菜单才会出现唯一的“开发：预览下一状态…”入口。普通 Debug、所有 Release（包括向 Release 单独注入该自定义条件）都没有预览入口或 `NSPanel` controller。默认 xcconfig 与 legacy 构建脚本不定义自定义条件，也没有 UserDefaults、环境变量或远程开关。

预览只使用写在源码里的固定、非敏感 fixture 和点击菜单时的鼠标位置。它不会读取真实选区、剪贴板旧内容或用户配置，不调用 localhost/URLSession/后端，不接入原生双 Option harness，也不改变 Hammerspoon/Lua。当前 live 双 Option、翻译请求和译文浮窗仍完全由 Hammerspoon 负责。

重复点击同一个入口会按内存中的确定顺序循环：loading、Apple success、火山 success、合法火山→Apple fallback、无 CTA 的火山网络错误、Copy 失败反馈、长文+截断、no selection、secure、unsupported、Accessibility CTA、服务错误+诊断 CTA、Apple 语言包 CTA、火山凭据 CTA、Apple→火山隐私拒绝。菜单会显示下一个状态名；索引不写入磁盘。loading 使用同一 generation 时钟，下一次点击会取消旧计时器并以新 generation 接管。panel 内不出现任何开发标签或 fixture 选择器。

## 组件边界

- `NativeTranslationOverlayModel.swift`：纯 reducer、隐私/引擎矩阵、稳定文案、精确复制 policy，以及 generation-gated 可注入时钟。loading 在 150 ms 后显示，2 s 原位更新，12 s 进入结构化错误；快速终态不闪 loading，迟到 timer/终态不能覆盖或重开。
- `NativeTranslationOverlayAnchorPolicy.swift`：只接收 AppKit 全局 point 中的 selection fixture、mouse point 与 visible frames。它不读取 AX、NSScreen 或 backing scale；按 selection 下/上/右/左（10 pt）及 mouse 右下/右上/左下/左上（12 pt）放置，并始终尊重 visibleFrame 12 pt inset。
- `NativeTranslationOverlayInteractionPolicy.swift`：纯 outside/Escape/Control-F6/Cmd-C、显式键盘模式的 PageUp/PageDown/Home/End/方向键正文滚动、焦点恢复和显示动画 revision policy，以及 scoped global/local monitor token 的幂等 owner。
- `NativeTranslationOverlayController.swift`：整个文件的实现位于双编译条件内。`@MainActor` singleton 只创建并复用一个 borderless、nonactivating `NSPanel`；默认只 `orderFrontRegardless`，不 activate、不 makeKey。Control-F6 或显式“聚焦当前译文”命令是唯一进入键盘模式的路径。

success 正文只显示 reducer 接收的 result；footer 显示实际引擎和整数毫秒。只有合法的火山云端→Apple warning 可显示 fallback，Apple→火山或无 warning 的引擎不一致会 fail closed。任意 error 都在检查 result 前返回固定文案，因此 backend echo、HTTP/AX/upstream/credential 细节不会进入正文、辅助说明或复制内容。

复制只在当前 generation 的可见 success 中可用。用户明确点击“复制”或在显式键盘模式按 Cmd-C 时，才会先准备完整译文、清空系统 pasteboard 并写入一个新的文本 item；实现从不读取旧 pasteboard，也不会自动用 pasteboard 取词。复制成功后 panel 保留 1.2 s“已复制”反馈，失败显示“复制失败”，均不自动关闭。AppKit 不提供原子替换，若清空后的系统写入罕见失败，旧剪贴板内容无法恢复；界面不会伪装为复制成功或静默重试。

## 被动 panel 与辅助功能

panel 使用单层 semantic material、系统阴影、14 pt continuous 圆角及 1 pt 语义 separator 外描边（Increase Contrast 时 2 pt）；Reduce Transparency、Increase Contrast、Reduce Motion、Light/Dark 会动态响应。loading 使用系统小型 indeterminate progress indicator。截断状态使用图标、浅色 capsule、可读的 label 文字与精确 AX help，橙色只作非文字强调。字体以 14/13/12/11 pt 为默认基线并跟随系统 preferred body text scale；大字时允许 panel 增高，空间不足则只压缩可滚动的 body viewport。正文不可选择，长文只在 body viewport 纵向滚动，header/footer 保持固定；被动模式不接收键盘，用户显式 Control-F6 聚焦后可用 PageUp/PageDown、Home/End 与上下方向键滚动。每次状态交换都会依据当前可见控件重建 CTA→Copy→Close 的 Tab 链；仍可见的 first responder 会保留，已经隐藏的控件会把焦点安全迁到新的首个控件，Space/Return 行为不变。

状态交叉淡入淡出严格先将旧内容淡出，在同一个主线程 swap 边界原子提交新视觉与其 generation，再淡入新内容；Reduce Motion 下直接瞬切。等待 loading 或淡出旧视觉期间 Copy/CTA 会禁用，绝不会出现“看到旧译文却复制或导航到新状态”。pending presentation 必须与当前 session generation 一致；新 session 会先清除旧 pending，因此屏幕重排不能复活已取消状态。每次普通 visibleFrame/辅助显示设置变化都会把当前可见 terminal 交给同一 VoiceOver current/visible/terminal/once gate：无论变化发生在 swap 前还是 fade-in 完成前都不会漏播，已经公告的 generation 也不会重播。旧动画 revision 无权交换或重显新 generation。

可见期间才安装 scoped global/local mouse/key monitors；local handler 始终返回原事件。外部点击和 Escape 关闭但不吞事件，内部正文/滚动区域不关闭。关闭、暂停、停止、撤权、显示器拔除、Space 切换、session resign 与 sleep 都使旧 generation 失效并移除 tokens。普通 Dock/分辨率/visibleFrame 变化只增加独立 layout revision、同步 reclamp；content generation、Copy 状态、loading timer 与 VoiceOver 公告都不重置。只有 anchor display ID 消失才关闭。

只有已经由用户显式进入键盘模式、随后用 Close/Escape 退出、且隐藏动画结束时句译仍是前台 App，才允许恢复此前的 source App。outside、Space、session、sleep、terminate 等被动/生命周期关闭永不激活旧 App；如果用户在隐藏动画期间选择了第三个 App，也不会被抢回焦点。

window accessibility title 是“句译译文”，内容顺序为标题、正文、metadata/截断信息、CTA、Copy、Close。每个 terminal generation 最多公告一次简短状态，不朗读全文、不移动 VoiceOver focus；复制另发一次简短公告。

## 自动验证与剩余门槛

CI 覆盖 reducer/引擎隐私/error echo、149/150 ms 等手动时钟边界、copy exactness、monitor token cleanup，以及负原点/横竖多屏/60% selection/locked edge/visibleFrame inset 等 anchor policy。构建矩阵覆盖默认 Debug、显式预览 Debug、默认 Release 和单独注入 flag 的 Release，并检查非预览二进制不含 controller/fixture。

本切片不会自行运行或安装 GUI。生产启用前仍必须真机验证：TextEdit/Safari 的前台与选区不变、outside/Escape 透传、同一 windowNumber、Control-F6/Full Keyboard Access、长文 PageUp/PageDown/Home/End/方向键与按钮 Tab/Space/Return、状态栏菜单 tracking、多屏/fullscreen/Stage Manager/Space、VoiceOver、200% 字体与各显示辅助设置。真实 AX bounds、localhost 请求和跨进程原生/Hammerspoon owner lease 都是后续独立 P0；在完成前不得连接 live 双 Option。
