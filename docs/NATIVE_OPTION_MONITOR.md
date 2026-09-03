# 原生双 Option 翻译

状态：**Apple 离线翻译 MVP 已接入普通 Debug 与 Release 构建。**

用户在句译中明确点击“启用原生双 Option”后，生产链路依次执行：

1. 检查 macOS 辅助功能授权与英语→简体中文 Apple Translation 语言包；
2. 通过现有 owner 协议请求 Hammerspoon 停止旧监听、在途请求和浮窗；
3. 安装 AppKit global `NSEvent` monitor，识别两次完整的 Option 按下/释放；
4. 在专用串行 worker 上读取触发时前台进程的真实 AX 选区；
5. 使用 macOS 15 Translation framework 在本机翻译；
6. 在触发时的鼠标位置附近显示原生非激活浮窗。

这条生产链不依赖 `JUYI_NATIVE_OPTION_MONITOR` 或其他编译 flag。用户停用、切换到火山云端、暂停、停止服务、睡眠、会话退出、辅助功能撤销或 App 终止时，会先撤销原生 monitor、取词、翻译和浮窗，再归还 Hammerspoon owner。异步语言检查不能越过这些生命周期边界重新启动监听。

## 取词范围

主路径使用 Apple Accessibility API，并在读取前后核对触发时的 `PID + NSRunningApplication.launchDate`、前台 App 和 AX 元素身份；bundle ID 只作元数据，focused element 还会用 `CFEqual` 复验。它支持常见原生文本框/文本区，以及 Safari、Chromium、Electron 和支持 AX text marker 的 PDF/网页静态文本。安全输入框、受保护内容、扫描图片和没有可访问文本层的 PDF 会拒绝读取；后两类需要 OCR，不属于本 MVP。

WPS PDF 没有提供可用 AX 选区时，只有在确认当前前台进程仍是同一 WPS 实例、焦点窗口仍是同一 PDF 后，才会临时发送系统 Copy。句译先保存剪贴板，以两个不同的唯一 marker 连续执行两次 Copy；只有两次稳定纯文本及完整 pasteboard 数据指纹完全一致才会进入翻译，并仅在最后的 change count 没有再变化时恢复原内容。marker 回写、旧文本恢复、两次结果不一致或捕获取消都会拒绝翻译。macOS pasteboard 不提供写入方身份，因此确定性改写剪贴板的管理器仍可能干扰该 best-effort 兼容路径；界面会明确披露。除 WPS PDF 外不使用剪贴板回退。

## 权限与隐私边界

- 只有用户点击启用按钮时，才会调用 `AXIsProcessTrustedWithOptions` 请求辅助功能授权；启动和恢复只做只读检查。
- monitor 只观察 `flagsChanged` 与 `keyDown`，不读取字符内容，也不能修改目标 App 的事件。
- 选区和译文不写日志、不落盘、不经网络；第一阶段只接 Apple 离线翻译。
- 每个 AX 消息有 500 ms 上限；第二次触发、前台切换、暂停或关闭会让旧结果失效。

Apple API 依据：[`addGlobalMonitorForEvents`](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29)、[Cocoa Event Handling Guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html) 与 [`kAXSelectedTextAttribute`](https://developer.apple.com/documentation/applicationservices/kaxselectedtextattribute)。

## 发布前仍需完成

- 在 macOS 15 真机和干净 TCC 状态验证 TextEdit、Safari/Chromium/Electron、Preview PDF 与 WPS PDF；
- 验证多显示器、快速重复触发、浮窗关闭/外点/CTA、暂停、睡眠、权限撤销和崩溃恢复；
- 对 Universal 2 `.app` 完成 Developer ID 签名、公证、DMG 和 GitHub Release。
