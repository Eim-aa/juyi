# 句译 juyi

![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)
![Engine](https://img.shields.io/badge/engine-offline%20%2B%20Volcengine-blue.svg)

> macOS 英语划词译为简体中文：在支持的 App 中选中英文，**连按两次 Option（⌥⌥）**。默认使用 Apple 端上翻译，正文在本机处理；首次使用可能需要系统下载语言包。

English: [README_EN.md](README_EN.md)

> **开发者预览，不是正式发行包。** 当前尚无已完成 Developer ID 签名、公证的公众下载包；下方是源码安装路径。预编译原生 App 的 Apple 翻译不依赖 Python 后台，但当前仍需 Hammerspoon 兼容组件、macOS 15+、句译辅助功能权限及系统中英语言包。详见 [安装与使用说明](docs/MENU_BAR_APP.md)。

Xcode 工程构建 Universal 2 App 与兼容 helper；构建通过不等于具备公开发行条件。见[构建与发行边界](docs/RELEASE_BASELINE.md)、[本轮产品审查与待验收项](docs/PRODUCT_REVIEW_2026-09-22.md)。

![demo](docs/demo.gif)

演示用于说明划词交互，不作为当前候选包界面或兼容性验收证据。

## 为什么用这个？

句译聚焦一个动作：选中英文，快捷查看中文。

- **默认本机处理**：走 macOS Translation framework；翻译正文不发送给句译作者或第三方云服务。
- **无需手动安装模型**：应用不携带模型文件；首次使用时系统可能提示下载中英语言包，之后可离线工作。
- **可选云端引擎**：需要对比长句或专业内容效果时，可在 App 中显式配置火山翻译；启用前会明确说明文本将上传。
- **双击 Option 触发**：选中英文，连按两下 ⌥，译文浮窗就近弹出。

定位刻意做窄：**只做英→简体中文、只做划词、只支持 macOS**。不提供 OCR。其他 App 和文本 PDF 能否取词取决于它们的辅助功能接口；扫描图片、安全输入框和受保护内容不支持。原生链只有 WPS PDF 使用受限剪贴板兼容路径，不能据此推断所有可选文本 App 都兼容。

## 用 AI Agent 协助源码安装

可以让 AI Agent 按仓库说明检查环境并执行源码安装：

```
请按 https://github.com/Eim-aa/juyi 的 AGENTS.md 帮我安装 句译（juyi）。
```

Agent 可以：克隆仓库、检查依赖、编译苹果端上翻译助手、注册后台服务、接好 Hammerspoon owner 交接模块、跑通可自动化的验证。详细步骤见 [AGENTS.md](AGENTS.md)。

以下步骤仍需你本人完成：

1. **授权（必做）**：按句译首次设置的提示，在「系统设置 → 隐私与安全性 → 辅助功能」里给 **句译** 打勾。这是 macOS 的安全限制（TCC），任何脚本或 Agent 都无法代劳。
2. **首次使用验证**：需要时确认系统语言包下载，然后在“文本编辑”中选中英文并试用双 Option；后台自检不能替代这一步。
3. **云端 API Key（只有想用云端时才需要）**：去[火山引擎控制台](https://console.volcengine.com/)注册、开通「机器翻译」、创建一对 AK/SK，并由你本人在句译 App 中录入。密钥保存在 macOS 钥匙串中，不需要粘贴给 Agent。

> 安全提示：不要把 Secret Key 粘进聊天、源码、终端历史或提交到 Git。旧版 `volc.env` 密钥会在 App 启动时迁移到 macOS 钥匙串；该文件之后只保留非敏感的引擎偏好。

## 安装（手动）

这是开发者源码安装路径，需要 macOS 15+、Homebrew、Python ≥ 3.10，以及可用的 Xcode/Command Line Tools 编译环境。**这些源码构建依赖不等于原生 Apple 路径的运行依赖**：已构建的 App 直接调用系统 Translation framework，不需 Python 服务；本预览版仍要求安装并打开 Hammerspoon。可选云端及旧兼容服务仍使用 Python 后台。

一行装（克隆到 `~/.local/share/argos-translator` 并执行安装脚本）：

```bash
curl -fsSL https://raw.githubusercontent.com/Eim-aa/juyi/main/scripts/bootstrap.sh | bash
```

或者手动 clone：

```bash
git clone https://github.com/Eim-aa/juyi.git ~/.local/share/argos-translator
~/.local/share/argos-translator/scripts/install.sh
```

安装脚本会检查 Homebrew、Python ≥ 3.10、磁盘空间，创建 venv 并装 `requirements.txt`，在 macOS 15+ 上编译苹果端上翻译助手，加载仅监听 `127.0.0.1:54321` 的 LaunchAgent，并以受管代码块接入 Hammerspoon。安装时还会生成仅当前用户可读的本地 API 令牌。

`scripts/install_macos_app.sh` 只重新构建和安装 App，不是完整依赖安装器。完整源码安装完成后，“句译”位于系统“应用程序”文件夹的 `/Applications/句译.app`，可从 Launchpad、Dock 或菜单栏打开。关闭控制窗口继续翻译；暂停或退出会停止原生与旧兼容快捷键链，退出后重开需点击“恢复句译”。首次打开会尝试开启登录启动，可在“诊断与帮助”关闭。

**默认是苹果端上翻译引擎（macOS 15+）**。应用无需手动安装模型；首次使用时系统可能弹出一次中英语言包下载确认，之后可以离线工作。云端引擎为可选，见下方“翻译引擎”。

装完后打开“句译”，按两步首次设置完成启用：

1. 点击启用原生双 Option。必要时，句译会部署安装包内的当前 Hammerspoon owner 交接模块并重新启动 Hammerspoon；随后会提示你在“系统设置 → 隐私与安全性 → 辅助功能”中授权 **句译**，授权后回到句译即可继续。
2. 点击“打开文本编辑”，新建文稿，输入并选中 `Good tools should feel effortless.`，再**连按两次 Option（⌥⌥）**。看到原生译文浮窗后回到句译确认。句译自身窗口不作为取词目标。

原生 Apple 链路由句译负责双 Option 监听、AX 取词、端上翻译和浮窗；Hammerspoon 不再处理这条链的取词或显示，只按现有 owner 协议安全停止并让出旧监听、请求和浮窗。

> Fork 部署前按 [AGENTS.md](AGENTS.md) 检查仓库链接与 LaunchAgent 标识；不要把本地构建称为已公证发行包。

## 本地 vs 云端：怎么选？

|          | 苹果端上（离线，默认且推荐） | 云端翻译（火山引擎，可选）         |
| -------- | ---------------------------- | ---------------------------------- |
| 适用场景 | 单词、短句、一般长句；隐私敏感内容 | 愿意上传，并想用固定语料对比效果 |
| 优势     | 隐私：文本不出本机；无需密钥 | 可在特定长句或专业语料上自行对比效果 |
| 联网     | 语言包一次性由系统下载，之后全离线 | 每次翻译走 HTTPS 到火山 API    |
| 配置     | 无需密钥（macOS 15+） | 需注册火山、拿一对 API Key         |

**推荐从 Apple 离线开始**：它是默认模式，不需要密钥，正文不离开本机。如果你的固定语料在实际对比中更适合火山翻译，再显式启用云端。不同引擎的效果取决于文本领域，不在没有盲评数据时承诺谁“明显更好”。

## 翻译引擎（可选切到云端）

引擎默认是 `apple`（苹果端上，离线），运行时选择记录在本地配置目录。火山 AK/SK 保存在 macOS 钥匙串；`~/.config/argos-translator/volc.env` 只作为旧版迁移来源及非敏感默认引擎配置。

**切换到火山翻译（Volcengine）云端引擎：**

1. 在[火山引擎控制台](https://console.volcengine.com/)开通"机器翻译"，给（子）用户授予 `TranslateFullAccess`，创建一对 AK/SK。
2. 先完成可选云端后台安装。打开主窗口的“其他翻译方式与已有设置”，点击“使用火山云端…”，由你本人输入 AK/SK。已有密钥与配置仍可在这里管理；首页简化不会删除它们。
3. 句译会先把候选凭据放入独立的待验证钥匙串项，真实翻译通过后才替换正式凭据；该事务标记会保留到后台服务重启并再次实测成功，意外中断时由下次启动继续恢复。验证失败不会覆盖原有可用配置。
4. 移除云端配置时会先建立本机事务标记；在移除完成前，快捷键端和本地服务都会阻止云端请求，即使 App 在中途退出也不会继续上传新选中的文本。

火山引擎用 AK/SK V4 签名（实现见 [`volc_engine.py`](volc_engine.py)，纯标准库）。此模式下选中文本会经 HTTPS 发往火山 API；是否更适合你的内容，应以自己的语料对比为准（见“隐私”）。

### 苹果端上引擎（macOS 15+，默认且推荐）

原生 App 直接使用 macOS Translation framework 完成默认 Apple 翻译。源码安装器也会编译 [`apple/TranslationHelper.swift`](apple/TranslationHelper.swift) 供旧服务兼容使用；它不是当前原生划词链的翻译进程。

- **应用不捆绑模型**：模型和语言包由系统管理，首次使用可能需要 macOS 下载语言包。
- **端上运行**：正文在本机处理；速度受冷启动、系统负载和语言包状态影响，不承诺固定延迟。
- 需要语言包时，按首次设置或“诊断与帮助”中的“准备 Apple 语言包”操作，确认 macOS 下载窗口。Apple 自测和语言包准备均走原生路径，不以 Python `/health` 成功为就绪依据。

### 运行时一键切换（菜单栏，无需重启）

装好后菜单栏会出现句译图标。点击“翻译方式”可切换已准备好的引擎，当前模式带勾显示、选择会被记住。主页优先展示 Apple 离线及快捷键状态，云端配置放在“其他翻译方式与已有设置”。旧版 `volc.env` 中的 `ENGINE` 只在没有明确选择时作为默认值。

成功译文下方标注**来源和本次耗时**，例如 `Apple 离线 · … 毫秒`。

本轮 Apple-only MVP 不扩展新引擎、多语言或翻译历史。

## 架构

```mermaid
flowchart LR
    U["用户在句译中启用原生双 Option"] --> O["owner 协议交接"]
    O --> H["Hammerspoon 停止旧监听、请求和浮窗"]

    subgraph APP["句译原生 Apple 链路"]
        N1["全局双击 ⌥ 监听"] --> N2["AX 读取当前外部 App 选区"]
        N2 -.仅 WPS PDF 兼容路径.-> N3["两次定向 Copy + 剪贴板快照恢复"]
        N2 & N3 --> N4["Apple Translation 端上翻译"]
        N4 --> N5["原生 AppKit 译文浮窗"]
    end

    H --> N1
```

切换到火山云端会停用这条 Apple 原生链并安全归还 Hammerspoon owner；可选云端翻译仍通过本地 FastAPI 服务调用火山 API。

## 常用命令

```bash
~/.local/share/argos-translator/scripts/test.sh        # 全套诊断
~/.local/share/argos-translator/scripts/bench.sh       # IPC + 翻译性能基准
~/.local/share/argos-translator/eval/run_eval.py       # 翻译质量评估
~/.local/share/argos-translator/scripts/demo.sh        # 简短交互演示
```

## 故障排查

| 现象                | 诊断                                                                                            | 修复                                                                                            |
| ------------------- | ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| 双击无反应          | 先看是否暂停，再在文本编辑中试用；打开句译“诊断与帮助” | 恢复句译；为**句译**授权辅助功能；按界面更新兼容组件并重新启用 |
| 云端服务无法访问    | 诊断中的云端组件状态 | 选择“修复云端组件”；Apple 原生翻译不需要此服务 |
| 火山返回报错        | 浮窗显示「⚠️ 云端翻译出错」及脱敏原因                                                            | 在句译中重新验证钥匙串里的 AK/SK，并确认已授 `TranslateFullAccess`、机器翻译已开通             |
| Apple 未准备好或超时 | 按原生错误浮窗进入句译；查看语言包与权限状态 | 准备 Apple 语言包或重新选中英文重试；不需要重启 Python 服务 |
| 某个 App/PDF 无法取词 | 确认有真实文本层，并先在文本编辑验证 | 扫描图片、受保护内容不支持；反馈 App 名称、版本和非敏感复现步骤 |
| WPS 剪贴板受干扰 | 检查是否有剪贴板管理器 | 敏感内容避免使用兼容取词；反馈时不要附原文或剪贴板内容 |

## 隐私（离线 vs 云端）

引擎用菜单栏实时切换，**默认离线**。

- **苹果端上模式（默认，`apple`）**：翻译由 macOS 系统的端上模型完成，选中文本不出本机、不经过任何第三方服务器；中英语言包由系统一次性下载与管理。
- **云端模式（`ENGINE=volc`）**：你选中的文本会通过 HTTPS 发送到**火山翻译 API** 以获取译文——此模式**不再离线**。是否启用完全由你掌控（默认关闭）。AK/SK 保存在 macOS 钥匙串，不写入仓库、源码或运行日志。
- **WPS PDF 兼容取词**：可能临时执行系统复制，并尽力恢复原剪贴板。剪贴板管理器可能保留原文或干扰取词；本机翻译不意味着这条兼容路径对其他剪贴板软件不可见。敏感内容请避免使用该路径。

## 致谢

- macOS [Translation framework](https://developer.apple.com/documentation/translation)——默认端上翻译引擎
- [火山翻译 / Volcengine](https://www.volcengine.com/product/machine-translation)——可选云端翻译引擎
- [Hammerspoon](https://www.hammerspoon.org/)——旧快捷键链与当前原生链之间的 owner 交接桥接
- [Argos Translate](https://github.com/argosopentech/argos-translate) / [CTranslate2](https://github.com/OpenNMT/CTranslate2) / [Stanza](https://github.com/stanfordnlp/stanza)——早期版本的离线引擎，在此致谢

## License

MIT，见 [LICENSE](LICENSE)。
