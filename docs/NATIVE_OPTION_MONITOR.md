# 原生双 Option 监听：阶段 1 开发说明

状态：**开发中，默认未启用，不是当前用户功能。**

当前 Release 构建在编译期硬关闭原生监听。普通 Debug 构建也保持关闭；只有开发者显式加入 `JUYI_NATIVE_OPTION_MONITOR` 编译条件时，内部 harness 才会启动 listen-only 事件监听，而且识别成功后只增加内存计数，不读取选区、不请求翻译、不显示浮窗。

因此目前唯一生效的双 Option 触发、取词和译文浮窗仍由 `hammerspoon/argos-translator.lua` 提供。这个切片没有替换、暂停或修改 Hammerspoon 链，也不表示句译已经去除 Hammerspoon/Python 依赖。

## 已建立的基础

- `DoubleOptionStateMachine.swift`：无 AppKit/CoreGraphics 依赖的纯识别策略；每次按住与两次释放间隔都以 350 ms 为上限。
- `NativeOptionMonitor.swift`：listen-only `CGEvent` tap 适配器，仅订阅 `flagsChanged` 与 `keyDown`；事件始终透传，识别结果在退出底层回调后异步投递。
- `AccessibilityController.swift`：为未来原生取词单独提供状态查询和名称明确的显式请求方法；事件监听器不依赖它，生产默认启动流程也不会调用请求方法。
- `NativeOptionFeature.swift`：Release 编译期恒为 `false`；Debug 还需额外编译条件，且内部回调只计数。

与 Lua 的正常手势一致，窗口按“释放到释放”计算。原生策略有意更保守：普通键或 Command/Control/Shift/Fn 无论出现在按住期间还是两次 tap 之间，都会取消整组，降低未来双触发或误触发风险；Caps Lock 被忽略。

事件 tap 在 start、stop、暂停/恢复、系统因 timeout/user input 暂停 tap 时都会清空手势状态。stop 可重复调用；系统禁用事件到来时仅在仍处于 started 且非 paused 状态下安全重新启用。

listen-only 事件监听所需权限与未来取词所需的 Accessibility 权限不是同一判断。当前内部监听器会直接尝试创建 tap，失败时只返回中性的“不可用”，不猜测具体权限原因，也不会发起任何授权请求。Input Monitoring 的最终产品权限策略仍待后续真机裁决；本切片不增加相关用户引导。

## 内部验证方式

纯状态机不需要运行 App：

```bash
swiftc -parse-as-library \
  macos/DoubleOptionStateMachine.swift \
  tests/DoubleOptionStateMachineTests.swift \
  -o /tmp/double-option-state-machine-tests
/tmp/double-option-state-machine-tests
```

开发者若要验证底层监听，只能在 Debug 中显式添加 `JUYI_NATIVE_OPTION_MONITOR` 编译条件。此模式仍不会调用翻译。此开关不读取 UserDefaults、环境变量或远程配置，也不会出现在用户界面。

## 尚未实现

- 用原生监听接管生产热键；
- 原生选区读取、剪贴板回退或译文浮窗；
- 与 Hammerspoon 的迁移/互斥策略；
- 用户可见的开关、状态或完成态变化。

这些内容必须在后续切片单独设计和验收。在此之前，不得把本文件描述为“已原生化”或“已去除外部依赖”。
