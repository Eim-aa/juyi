# 句译质量评估表（RUBRIC）

本表把 Apple Design Awards 的六个评选维度翻译成对**句译这个具体产品**可检查的条目。Apple 没有公开数值评分标准，所以本表不模仿“Apple 打分”，只做三件事：逐条检查、要求证据、机械计算。它是**质量视角**，不是获奖预测。

> 本文件是循环的只读控制文件，运行中不得修改（门禁会拒绝）。

## 使用规则

1. 每个条目只能判为 `pass` / `fail` / `unknown` 三种。**没有证据就是 `unknown`，不是 `pass`，也不是 `fail`。**
2. 证据格式：代码用 `路径:行号` 加不超过 100 字符的原文摘录；截图用文件名加你实际看到的现象。不接受“看起来不错”“应该没问题”。
3. 不要为了让清单变长而硬找问题。一个已经做对的条目就判 `pass` 并写出证据；本项目的辅助功能基础已经相当完整，大量条目预期是 `pass`。
4. 禁止使用的措辞：`优秀`、`完美`、`显著提升`、`极大改善`、`达到获奖水平`。只写事实与证据。
5. 每个 `fail` 必须带：严重度（1–3）、修复层级（A/B/C）、一句话的具体修复建议。

## 分数计算（机械的，不凭感觉）

对每个维度分别计算：

```
score    = Σ权重(pass) / Σ权重(pass + fail)         ← 已核查部分的通过率
coverage = Σ权重(pass + fail) / Σ权重(全部条目)      ← 有多少条目真的被核查过
```

- 只报告每个维度的 `score` 与 `coverage`，**不要求也不允许合成一个总分**。
- `coverage` 低于 0.6 的维度，必须在报告里写明缺什么证据（通常是缺截图）。
- 严重度：`3` = 阻碍用户或辅助技术完成任务；`2` = 造成困惑或体验明显变差；`1` = 打磨级别。

## 修复层级

| 层级 | 含义 | 夜间循环能做什么 |
| --- | --- | --- |
| **A** | 只改辅助功能元数据、用户可见文案、语义颜色、减少动态效果守卫、`.help` 提示、键盘快捷键声明。不改任何逻辑与布局。 | 直接修复并提交（受门禁约束：每轮 ≤2 个文件、≤60 行） |
| **B** | 涉及布局、几何、交互行为、动画、新增控件，或超过 A 的体量，但目标文件在可编辑名单内。 | 只出**已验证可编译的补丁**，不提交 |
| **C** | 需要改只读文件，或需要真机/真人判断，或是产品决策。 | 只写分析与建议，不改代码 |

可编辑文件名单由 `scripts/quality_gate.sh` 强制，不由提示词决定。

---

## 维度一 · Interaction（交互）

| ID | 权 | 检查什么 | 怎么查 | 通过条件 | 层 |
| --- | --- | --- | --- | --- | --- |
| I-01 | 3 | 首次成功路径的长度 | 列出 `onboardingScreen` 的全部取值与每屏必须的用户动作（`JuyiMenuBar.swift`） | 从首次打开到可翻译，必须的应用内步骤 ≤3，且每屏有且仅有一个默认主按钮 | B |
| I-02 | 3 | 取词失败的七种状态都有独立文案 | 在 `NativeTranslationOverlayModel.swift` 中找 `NativeTranslationOverlayCaptureStatus` 的每个 case：`noSelection` `secureField` `unsupported` `accessibilityRequired` `noFocusedElement` `temporarilyUnavailable` `cancelled` | 每个 case 的用户可见文案互不相同，且含“原因＋下一步”（`cancelled` 可无） | A |
| I-03 | 3 | 翻译失败的十五种状态文案 | 同文件 `NativeTranslationOverlayBackendError` 的每个 case | 每个 case 都有区分度的文案；超时类（`requestTimeout` `appleTimedOut` `volcTimeout`）含重试建议；不含内部术语（见 D-04） | A |
| I-04 | 2 | 可行动的错误都带按钮 | 对 I-02/I-03 的每个状态，看它是否映射到 `NativeTranslationOverlayCTA`（`openJuyi` `openDiagnostics` `prepareAppleLanguages` `checkCloudSettings` `chooseEngine`） | 凡是用户能做点什么的错误都有 CTA；没有 CTA 的要在证据里说明为什么用户无事可做 | A/B |
| I-05 | 2 | 浮窗关闭途径 | 在 `NativeTranslationOverlayController.swift` 与 `NativeTranslationOverlayInteractionPolicy.swift` 找：关闭按钮、点击浮窗外、`Esc` 键（`cancelOperation`/`keyDown`） | 三种途径都存在 | B |
| I-06 | 2 | 浮窗不抢走来源 App 的焦点与选区 | 找 `nonactivatingPanel`、`canBecomeKey`、`becomesKeyOnlyIfNeeded` 等 | 能给出代码证据证明弹出不会激活句译、不会让来源 App 失去选区；**只读核查，不要改** | C |
| I-07 | 2 | 复制后的反馈 | 找 copy 按钮点击后的标题变化与 `NSAccessibility.post(... announcementRequested ...)` | 既有可见反馈，也有 VoiceOver 播报 | A |
| I-08 | 2 | 菜单栏菜单的结构 | 读构建菜单的代码（`NSMenu`、`item(` 附近）并结合截图 | 第一项反映当前状态；破坏性或退出项在末尾；总项数 ≤8；每个可点项以动词开头 | B |
| I-09 | 3 | 隐私披露出现在做选择的那一刻 | 看引擎选择处与云端配置表单的文案 | 选云端处明说“选中的英文会发送至火山”；Apple 路径处明说文本在本机处理；两处措辞与 `README.md`/`AGENTS.md` 一致 | A |
| I-10 | 2 | 云端密钥表单的可用性 | 读云端表单（`Access Key ID` / `Secret Access Key` 附近） | `SecureField` 为默认；“显示/隐藏”按钮的可访问名称随状态变化；忙碌与错误状态会被播报；失败文案带图标且说明下一步 | A |
| I-11 | 2 | 暂停/退出/关闭窗口/恢复的措辞一致 | grep 全部用户可见字符串中的 `暂停` `退出` `关闭` `恢复` | 同一动作全程同一个词；任何两处说明不互相矛盾 | A |

## 维度二 · Inclusivity（包容性）

| ID | 权 | 检查什么 | 怎么查 | 通过条件 | 层 |
| --- | --- | --- | --- | --- | --- |
| N-01 | 3 | 每个可交互控件都有可读名称 | 枚举 `JuyiMenuBar.swift` 的 `Button` `Toggle` `TextField` `SecureField` `Picker` 与仅含图标的控件；枚举浮窗里的 `NSButton` | 全部有文字标题或 `accessibilityLabel`；逐个列出，别抽样 | A |
| N-02 | 2 | 装饰性图像对辅助技术隐藏，信息性图标有标签 | grep `Image(systemName:` 与 `NSImageView` | 纯装饰的有 `accessibilityHidden(true)` / `setAccessibilityElement(false)`；承载信息的有标签 | A |
| N-03 | 2 | 页面/窗口标题是 header | grep `isHeader`，对照每个窗口与页面的主标题 | 每个页面主标题都带 `.isHeader`（引导页已有，核查首页、诊断页、云端表单、支持范围页） | A |
| N-04 | 3 | 状态变化会被播报 | grep `announcementRequested`、`announce(`；对照事件：浮窗出现、引导步骤切换、云端验证成功/失败、复制成功、暂停/恢复 | 上述每个事件都有播报；缺哪个就列哪个 | A |
| N-05 | 2 | 阅读顺序与分组 | 看 `accessibilityElement(children:)` 与浮窗的 `setAccessibilityChildren` | 复合行合并为一个元素；浮窗顺序为 译文→操作按钮 | A |
| N-06 | 3 | 所有动画遵守“减少动态效果” | grep `withAnimation` `.animation(` `.transition(` `NSAnimationContext` `CABasicAnimation`；对每一处找 `accessibilityReduceMotion` / `accessibilityDisplayShouldReduceMotion` | **每一处**都有守卫（降级为无动画或明显更短）。逐处列表，漏一处判 fail | A |
| N-07 | 2 | 降低透明度 / 提高对比度 | 浮窗已处理；核查 SwiftUI 窗口里的 `Material`、`.quaternary`、`.background(` | SwiftUI 窗口在“降低透明度/提高对比度”下仍可读（有 `accessibilityReduceTransparency` / `colorSchemeContrast` 处理，或只用不透明系统背景） | A/B |
| N-08 | 2 | 颜色不是唯一的信息载体 | 看状态展示（`state.symbol` / `Label(... systemImage:)`） | 每个状态同时有 图标＋文字，不只靠颜色 | A |
| N-09 | 2 | 颜色全部使用系统语义色 | grep `Color(red` `NSColor(red` `Color(white` `Color(hex` `#colorLiteral` | 零处原始 RGB/十六进制；固定色必须在证据里说明为何不随深浅色变化 | A |
| N-10 | 2 | 键盘可达 | grep `keyboardShortcut` `cancelAction` `defaultAction` `acceptsFirstResponder` `canBecomeKeyView` | 每个窗口/弹层都有默认与取消动作；浮窗按钮能被键盘到达或有明确理由不能（**浮窗是非激活面板，改焦点行为风险高，只提建议**） | B |
| N-11 | 2 | 点击目标不小于 24×24 pt（WCAG 2.2 SC 2.5.8） | 找所有固定 `.frame(width:height:)` 的按钮/图标按钮，以及浮窗按钮的尺寸约束 | 全部 ≥24×24；列出每个小于该值的控件 | A/B |
| N-12 | 1 | 朗读声音语言与文本语言匹配 | 读 `speechVoice(for:)` | 原文用英文声音、译文用中文声音；缺声音时有说明（代码已有缺失声音提示，核查文案） | C |
| N-13 | 2 | 译文可选可复制 | 找 `isSelectable` / `textSelection` | 浮窗译文可被选中；复制按钮存在 | C |
| N-14 | 1 | 字号使用语义样式 | `JuyiMenuBar.swift` 中 `size:` 的固定字号 | 固定字号仅用于展示性大标题（≥25pt）；说明与正文用语义样式（`.body` `.callout` `.caption`）。**不要声称 macOS 有 iOS 式 Dynamic Type** | A |

## 维度三 · Visuals and Graphics（视觉）

> 本维度大部分条目依赖截图。没有截图就判 `unknown`，**不得从代码推断视觉效果**。

| ID | 权 | 检查什么 | 怎么查 | 通过条件 | 层 |
| --- | --- | --- | --- | --- | --- |
| V-01 | 2 | 深色与浅色下都无截断、溢出、重叠 | 截图 | 每张截图逐一核对：按钮文字、说明文字、浮窗长文均完整显示 | B |
| V-02 | 2 | 每个屏幕只有一个视觉上最突出的主操作 | 截图＋`.borderedProminent` / `defaultAction` 计数 | 每屏 ≤1 个突出按钮 | B |
| V-03 | 2 | 间距体系 | 汇总 `.padding(` `spacing:` 的数值取值 | 不同取值 ≤7 种；超出则**只输出统一建议表**，不要直接改 | B |
| V-04 | 2 | 浮窗版式 | 读浮窗字号、行距、最大宽度、长文滚动，并核对截图 | 正文≥15pt；长文可滚动；有截断说明；中英混排行高无抖动 | B |
| V-05 | 1 | 菜单栏图标 | 找 `isTemplate` 与 `accessibilityDescription` | 模板图像＋有描述（代码已有，核查即可） | C |
| V-06 | 1 | 应用图标尺寸完整 | `macos/Assets.xcassets/AppIcon.appiconset/Contents.json` | 10 个尺寸文件齐全 | C |
| V-07 | 1 | 窗口默认与最小尺寸 | 读 `WindowFramePolicy` 与窗口创建处 | 有最小尺寸；默认尺寸在小屏上不超出可视区域 | C |

## 维度四 · Delight and Fun（愉悦）

| ID | 权 | 检查什么 | 怎么查 | 通过条件 | 层 |
| --- | --- | --- | --- | --- | --- |
| D-01 | 2 | “成功时刻” | 读引导完成页（“句译准备好了”）与第一次翻译成功 | 完成后立刻告诉用户“现在去做什么”；不是死胡同 | C |
| D-02 | 2 | 动效克制 | 汇总所有动画时长 | 全部 ≤0.25 秒；除加载指示器外无循环动画 | A |
| D-03 | 1 | 微反馈 | 复制、朗读开始/停止、关闭 | 每个动作都有即时的可见变化 | A |
| D-04 | 3 | 用户可见文案中没有内部术语 | grep 中文字符串里出现：`AX` `TCC` `owner` `handoff` `watcher` `helper` `LaunchAgent` `Python` `后台服务` `enum` `nil` `error code` | 除“检测到早期组件”清理流程里必须点名的 `Hammerspoon` 外，零处 | A |
| D-05 | 2 | 按钮文案规范 | 看所有按钮标题 | 以动词开头；会弹出进一步输入/确认的按钮带“…”（已有如“使用云端翻译…”）；同类按钮用词一致 | A |
| D-06 | 1 | 中英混排与标点 | 抽查全部用户可见字符串 | 中文标点全角；中英文/数字之间空格风格一致（全仓统一一种） | A |

## 维度五 · Innovation（创新）

| ID | 权 | 检查什么 | 怎么查 | 通过条件 | 层 |
| --- | --- | --- | --- | --- | --- |
| X-01 | 2 | 本地优先的承诺在使用点可见 | 浮窗引擎标签（`Apple 离线` / `火山云端`）、首页状态 | 用户在看到译文的那一刻能分辨文本是否离开了本机 | C |
| X-02 | 0 | **不计分**：最多 3 条“不新增功能”前提下的差异化想法 | 只写进报告 | 只写想法与理由，**不实现** | C |

## 维度六 · Social Impact（社会影响）

不适用于该产品，**不评估、不计分**。

---

## 只读深挖（不计分，必须写进报告）

**R-01 · 间歇性“不支持”的根因假设。** 仓库的发布文档明确写着该问题“根因未确证”。请只读分析 `NativeSelectionReader.swift`、`NativeSelectionCaptureCoordinator.swift`、`NativeOptionFeature.swift` 中会导致 `unsupported` / `temporarilyUnavailable` 的所有路径，列出最多 5 条假设。每条必须含：触发条件、对应代码位置、**置信度（高/中/低）**、人工在真机上可怎样验证。不允许修改这些文件。不允许把假设写成结论。

**R-02 · 文档与代码一致性。** `AGENTS.md` 写明“云端与本地之间没有回退，任何方向都没有”。核对 `NativeTranslationOverlayResponseWarning.usedAppleFallback` 这个符号是否仍被生产代码使用：若仍被使用，说明文档与行为矛盾；若是遗留死代码，说明可清理。只给事实与位置，不要改。
