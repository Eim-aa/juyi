# 句译 0.4.0 · build 12（独立原生公开测试版）

## 这次解决什么

全新 Mac 使用 Apple 本地翻译只需安装句译，不再先安装 Hammerspoon、Python 或 Homebrew。句译自身监听双 Option、读取选中文字、调用 Apple Translation，并展示译文浮窗。

用户仍需本人完成系统辅助功能授权，以及首次可能出现的语言包下载确认。这两项不应绕过。仅支持 macOS 15+、英语 → 简体中文；Universal 2 包含两种架构，不等于所有设备均已实测。

## 安装与使用

1. 从 [GitHub Releases](https://github.com/Eim-aa/juyi/releases) 下载标明已签名、公证的 build 12 DMG，不需要 GitHub 账户。打开后把句译拖入 Applications。
2. 从“应用程序”打开句译，点击启用双 Option，按提示允许句译使用辅助功能，并准备 Apple 中英语言资源。
3. 在文本编辑或文字型 PDF 中选中英文，连按两次 Option，查看中文浮窗。

如果这台 Mac 留有早期开发组件或正在运行 Hammerspoon，句译仍会先进行安全交接。不会因状态缺失、过期或解析失败而跳过互斥检查；暂停、退出和启用失败也必须在确认原生监听停止后释放 owner。没有新增交接协议或编译开关。

可选火山云端仍需独立后台及火山密钥，不属于这个原生本地安装流程。WPS PDF 兼容取词可能临时复制并尽力恢复剪贴板；不支持扫描图片、OCR、安全输入框或所有 App。

## 验证边界

- 已完成本地 Universal 2 Release 构建，以及独占启用、停止与既有交接的针对性回归检查。
- 自动检查不代替干净 macOS 账户的真实授权、语言包、双 Option、暂停恢复、退出重开验收。
- build 12 已安装到本机；此前 build 11 的 PDF 验收不能冒充 build 12 的 PDF 或首次安装结果。

## 实际发行与验收记录（2026-09-25）

- [公开测试版与免登录下载](https://github.com/Eim-aa/juyi/releases/tag/v0.4.0-preview.12)已发布，仍标记为 prerelease，不是稳定版。
- 安装包源码提交：`5e0a92f034aaa439d524541d99fc41b05c172185`。该提交的推送、合并请求及标签 CI 均已完成且通过；[推送检查记录](https://github.com/Eim-aa/juyi/actions/runs/36147070831)。
- Developer ID 签名、可信时间戳、Hardened Runtime、Apple 公证、staple 和 Gatekeeper 检查通过。已匿名下载实际发布 DMG，校验最终 SHA-256：`2b714832861f04227fb44c9027477be4b8d48b3dbcfd4dda8e64e69976006ecd`。
- 从该下载包更新至 `/Applications/句译.app`，核对版本 0.4.0 / build 12；旧版已另行备份。
- 实测环境为 macOS 26.5.1（25F80）、Apple Silicon。暂停 → 应用菜单正常退出 → 重开保持暂停 → 手动恢复至“已就绪”通过；此项不替代暂停时实际按键不触发的测试。
- 文本编辑中选中英文后，由用户本人双按 Option，用户明确确认“出现了中文译文”。因此本机实际选区 → Apple 本地翻译 → 中文浮窗链路通过，不是代理合成按键或引擎示例测试。
- Computer Use 在读取诊断页时自身崩溃，诊断页按钮自测未完成；主界面重开后可正常控制，不能将工具故障说成句译崩溃。

仍待验证：不含早期开发组件的干净账户首次安装、辅助功能授权及首次语言资源准备；build 12 的 PDF 场景；macOS 15 与 Intel 真机。现有本机保留早期开发配置，因此上述成功不能证明无 Hammerspoon 的全新安装链路已经实测通过。
