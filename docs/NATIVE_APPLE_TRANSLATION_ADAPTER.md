# 原生 Apple Translation 适配器（4B，默认关闭）

这是一个仅供开发验证的 macOS 15 Apple Translation 适配器切片，不是生产翻译链。它不会替换现有 Python 后端、Hammerspoon 双 Option 热键或浮窗，也不会在启动、状态轮询或普通 Debug/Release 构建中运行。

## 编译门与入口

实现、`import Translation`、App 接线和唯一菜单入口全部由以下编译条件共同保护：

```swift
#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER
```

仓库默认配置不定义 `JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER`。只有显式 opt-in Debug 构建才显示 App 主菜单项“开发：测试 Apple 离线翻译…”。状态栏菜单、公开设置、启动流程和 Release 都没有入口。固定样例精确为 `The weather is pleasant today.`，源语言固定 `en`，目标固定 `zh-Hans`。

## 用户动作边界

打开开发 sheet 只调用 `LanguageAvailability.status(from:to:)`，不会创建 session、请求下载或翻译。系统返回：

- `installed`：允许用户再次点击“翻译固定样例”。点击后会再次确认 `installed`，确认成功才请求 SwiftUI host。
- `supported`：只显示“准备语言包…”按钮。只有用户明确点击后才调用 `prepareTranslation()`，下载确认由 macOS 管理。
- `unsupported` 或暂时无法确认：零 session effect，也不会切换到火山云端。

“停止等待”只停止句译等待当前调用并作废 generation，不宣称取消系统下载；界面明确提示 macOS 可能仍会继续下载。准备调用没有硬超时，30 秒仅更新未知进度提示。availability 和 session host acquisition 各有 5 秒 fail-closed 门；固定翻译从用户点击起最多等待 12 秒，迟到结果不会发布。

## 生命周期与隐私

一个 `@MainActor` coordinator 持有唯一 generation。新请求、关闭 sheet、暂停、停止服务、切换引擎和 App 退出都会推进 generation、清除 host claim、timer、固定原文和译文。成功译文只保存在当前 sheet 的 typed outcome 中，关闭立即清除。

`TranslationSession.Configuration` 只存在 SwiftUI host 的 `@State`：新 request 会创建或 `invalidate()`，request 结束和关闭会设为 `nil`。`TranslationSession` 只在 `.translationTask` closure 内调用，不存储、不传入 detached task、不跨 actor。原始 `Error`、`localizedDescription`、固定原文和译文均不写日志。

该切片不读取选区、剪贴板、键盘输入或云端配置；不包含 URLSession、localhost、Keychain、文件、helper、Option monitor、AX、overlay 或 fallback。正文由 Apple Translation 在本机处理；准备语言包可能由 macOS 联网下载。Apple 可能收集 App 标识、源/目标语言等不含正文的使用和性能信息。

## macOS 15 API 约束

适配器只使用 macOS 15 已提供的 API：

- `LanguageAvailability.status(from:to:)`
- `TranslationSession.Configuration` 与 `invalidate()`
- SwiftUI `.translationTask`
- `prepareTranslation()`
- `translate(_:)`
- macOS 15 可用的 `TranslationError` 分类

明确禁止 macOS 26+ 的 `canRequestDownloads`、`isReady`、`cancel()`、`init(installedSource:target:)`、`preferredStrategy`、`TranslationError.notInstalled` 和 `alreadyCancelled`。

## 自动验证与尚未完成的真机门禁

纯 Swift 测试使用 fake availability、原子 host claim 和手动单调时钟，不等待真实时间；静态契约检查编译门、禁用 API、唯一 fixture、无生产入口和无敏感 I/O。CI 构建并扫描 default Debug、domain-only Debug、4B opt-in Debug、default Release 和 Release 注入两 flag，只有 4B opt-in Debug 可以包含 sentinel、菜单与固定样例。

当前开发机只有 Xcode 26 SDK，因此自动化只能证明源码以 macOS 15 为 deployment target 编译且未引用已知 26+ API。正式启用前仍必须在干净的 macOS 15.0、最新 15.x，以及继续承诺 Universal 2 时的 Intel Mac 上完成真实 Translation 服务、语言包确认/拒绝/断网/低空间、焦点、VoiceOver、Full Keyboard Access、休眠和取消矩阵。本切片不以 Xcode 26 上的编译结果冒充这些真机 P0 已通过。
