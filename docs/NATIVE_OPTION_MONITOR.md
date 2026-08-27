# 原生双 Option 监听：阶段 1 开发说明

状态：**开发中，默认未启用，不是当前用户功能。**

当前 Release 构建在编译期硬关闭原生监听。普通 Debug 构建也保持关闭；只有开发者显式加入 `JUYI_NATIVE_OPTION_MONITOR` 编译条件时，内部 harness 才会启动全局事件监听。识别成功后，它在专用串行 worker 上执行 AX 取词，并且只把稳定结果和文本保存在私有内存；不请求翻译、不显示浮窗、不输出文本日志。

因此目前唯一生效的双 Option 触发、取词和译文浮窗仍由 `hammerspoon/argos-translator.lua` 提供。这个切片没有替换、暂停或修改 Hammerspoon 链，也不表示句译已经去除 Hammerspoon/Python 依赖。

## 已建立的基础

- `DoubleOptionStateMachine.swift`：无 AppKit/CoreGraphics 依赖的纯识别策略；每次按住与两次释放间隔都以 350 ms 为上限。
- `NativeOptionEventAdapter.swift`：不携带字符内容的纯事件适配器；处理左右 Option、启动/恢复时 Option 已按住及 Caps Lock 等边界。
- `NativeOptionMonitor.swift`：`@MainActor` 的 AppKit 全局 `NSEvent` 监听器，仅订阅 `flagsChanged` 与 `keyDown`；回调不读取 `characters`，识别结果离开回调后异步投递。常态不安装 local monitor，因此句译自身前台不会触发。
- `AccessibilityController.swift`：提供只读状态和名称明确的显式请求方法。监听启动只查询状态，绝不调用请求方法。
- `NativeSelectionReader.swift`：AX-only 取词基础。它把触发瞬间的前台 PID/bundle ID 作为快照，读取前重新核对 PID、拒绝自身 PID、核对 focused element PID，并在读取 `AXSelectedText` 前拒绝 `AXSecureTextField`；没有剪贴板回退、文本日志或 UI 副作用。
- `NativeSelectionCaptureCoordinator.swift`：专用串行 worker 与 generation gate。被第二次触发、停止或授权变化取代的排队任务不会发起 AX；同步 AX 已开始时无法中断，但返回后会在进入主队列前丢弃过期文本。
- `NativeOptionFeature.swift`：Release 编译期恒为 `false`；Debug 还需额外编译条件，且内部结果只保存在内存，不接入后端或公开 UI。

与 Lua 的正常手势一致，窗口按“释放到释放”计算。原生策略有意更保守：普通键或 Command/Control/Shift/Fn 无论出现在按住期间还是两次 tap 之间，都会取消整组，降低未来双触发或误触发风险；Caps Lock 被忽略。

监听器在授权前不会安装 monitor。start、stop、暂停/恢复及授权撤销会维护独立的 token/授权状态并使旧 generation 失效；重复 start/stop/pause 不会重复安装或移除 token。授权恢复不等于监听已恢复，必须显式 start 重建。第二次触发会使尚未投递的第一次触发过期。

## Apple API 依据与权限边界

Apple 的 [`addGlobalMonitorForEvents`](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29) 文档明确：global monitor 异步观察发往其他 App 的事件，不能修改或阻止原事件；键盘相关事件只在 App 已启用/获信任使用 Accessibility 时可监听，而且不会收到本 App 的事件。Apple 的 [Cocoa Event Handling Guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html) 进一步说明回调位于主线程，monitor 用完必须显式 `removeMonitor`；global 与 local 的观察范围互斥。常态 global-only 是本阶段的产品决定，未来新手教学若需要本 App 内练习，将使用单独、页面级 scoped local，而不是 app-wide local。

因此原先 `CGEventTap` / Input Monitoring 路线已退役；当前开发实现不做 Input Monitoring 预检或引导。全局按键监听与 AX 主取词都以同一次 Accessibility 授权为前提，但 `AXIsProcessTrusted` 仅表示授权，不等于 monitor 已成功安装。正式启用前仍必须在干净 TCC 环境做真机验证。本切片不新增任何公开权限文案或自动权限弹窗。

Apple 将 [`kAXSelectedTextAttribute`](https://developer.apple.com/documentation/applicationservices/kaxselectedtextattribute) 定义为当前选中文本。系统 client 只通过 `AXUIElement` 获取目标 App 的 focused element 与该属性；每个相关 AX element 设置 100 ms messaging timeout，失败时按稳定结果分类并 fail closed。文本按现有后端策略依次统一 CRLF/CR、裁去首尾 Unicode 空白，并按 Unicode scalar 限制 5,000；内部空白、大小写与 Unicode 组合保持原样。

## 内部验证方式

纯状态机不需要运行 App：

```bash
swiftc -parse-as-library \
  macos/DoubleOptionStateMachine.swift \
  tests/DoubleOptionStateMachineTests.swift \
  -o /tmp/double-option-state-machine-tests
/tmp/double-option-state-machine-tests
```

CI 另外以可执行 Swift 测试覆盖 NSEvent 纯适配器、monitor 生命周期/授权撤销/generation、串行 capture gate，以及可注入 AX client 和 AXError/secure-field 纯策略；这些测试不会访问 TCC 或其他进程。

开发者若要验证监听与 AX 取词，只能在 Debug 中显式添加 `JUYI_NATIVE_OPTION_MONITOR` 编译条件。结果只留在进程私有内存，此模式仍不会调用翻译。此开关不读取 UserDefaults、环境变量或远程配置，也不会出现在用户界面。

## 尚未实现

- 用原生监听接管生产热键；
- 剪贴板显式兼容模式或原生译文浮窗；
- 与 Hammerspoon 的迁移/互斥策略；
- 用户可见的开关、状态或完成态变化。

这些内容必须在后续切片单独设计和验收。在此之前，不得把本文件描述为“已原生化”或“已去除外部依赖”。
