# argos-translator

> macOS 任意 app 划词英译中——**完全离线**，典型 ~150 ms，p95 ~400 ms。无需 API key，不走云端。

English: [README.md](README.md)

![demo](docs/demo.gif)

## 为什么用这个？

大多数 macOS 划词翻译要么要 API key（OpenAI、DeepL），要么把你的选中文本上传到云端。这个工具完全在本机跑：

|                | argos-translator (本项目) | [pot-desktop](https://github.com/pot-app/pot-desktop) | [openai-translator](https://github.com/openai-translator/openai-translator) | macOS 自带翻译 |
| -------------- | ------------------------- | ----------------------------------------------------- | --------------------------------------------------------------------------- | -------------- |
| 100% 离线      | ✓                         | 部分                                                  | ✗（需 API key）                                                             | ✓              |
| 系统级热键     | ✓                         | ✓                                                     | ✓                                                                           | ✗              |
| 任意 app 划词  | ✓（AX + 剪贴板兜底）      | ✓                                                     | ✓                                                                           | 受限           |
| 语言对         | 仅英→中                   | 55 种                                                 | 55 种                                                                       | 系统级         |
| 典型延迟       | 本地 ~150 ms              | 网络往返                                              | 网络往返                                                                    | 系统级         |
| GUI            | 浮窗                      | 完整窗口                                              | 完整窗口                                                                    | 系统级         |
| 安装方式       | brew + HS + 脚本          | DMG                                                   | DMG                                                                         | 内置           |
| License        | MIT                       | GPL-3.0                                               | AGPL-3.0                                                                    | 闭源           |

定位刻意做窄：**只做英→中、只做划词、只支持 macOS**。要 55 语言或 OCR 请用 pot-desktop。如果你只想"按个热键就出译文，文本永不外泄"，这个最简单。

## 安装

一行装（克隆到 `~/.local/share/argos-translator` 并执行安装脚本）：

```bash
curl -fsSL https://raw.githubusercontent.com/Eim-aa/argos-translator/main/scripts/bootstrap.sh | bash
```

或者手动 clone：

```bash
git clone https://github.com/Eim-aa/argos-translator.git ~/.local/share/argos-translator
~/.local/share/argos-translator/scripts/install.sh
```

安装脚本会检查 Homebrew、Python ≥ 3.10、磁盘空间，创建 venv 并装 `requirements.txt`，通过 `argospm install translate-en_zh` 从 Argos 官方包索引下载 `translate-en_zh-1_9` 模型（~150 MB），加载 LaunchAgent 监听 `127.0.0.1:54321`，并把 Hammerspoon 模块接进 `~/.hammerspoon/init.lua`。

**只有模型下载这一步需要联网**。装完之后运行时 100% 离线，见下方"离线隐私"。

装完后：

1. `brew install --cask hammerspoon`
2. 打开 Hammerspoon，在"系统设置"里给"辅助功能"权限。
3. 重新加载 Hammerspoon 配置。
4. 在任意 app 中选中英文，按 **Option+T**。

> Fork 后发布前，把所有 `Eim-aa` 替换为你的 GitHub 用户名：
> `grep -rl Eim-aa . | xargs sed -i '' "s/Eim-aa/<你的用户名>/g"`
> 再把 `launchd/io.github.Eim-aa.argos-translator.plist.template` 改名。

## 架构

```mermaid
flowchart LR
    A["选中文本"] --> B["Hammerspoon 按下 Option+T"]
    B --> C["AX selectedText"]
    C -->|兜底| D["Cmd+C 带剪贴板快照/恢复"]
    C --> E["HTTP POST 127.0.0.1:54321/translate"]
    D --> E
    E --> F["FastAPI 服务"]
    F --> G["单例 Argos / CTranslate2 翻译器"]
    G --> H["SHA-1 LRU 缓存"]
    H --> I["JSON 响应"]
    I --> J["hs.canvas 浮窗"]
```

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
| 热键无反应          | 打开 Hammerspoon Console                                                                        | 在"系统设置 → 隐私与安全性 → 辅助功能"给 Hammerspoon 权限，然后 Reload Config                   |
| 服务无法访问        | `launchctl print gui/$(id -u)/io.github.Eim-aa.argos-translator`                          | 跑 `scripts/launchd_install.sh`                                                                 |
| `/health` 失败      | `curl -s http://127.0.0.1:54321/health`                                                         | 看 `~/Library/Logs/argos-translator.err.log`                                                    |
| 首次请求很慢        | `tail -50 ~/Library/Logs/argos-translator.err.log`                                              | 确认日志里有 `model_warmup_done`                                                                |
| 剪贴板被改         | 手动跑 `pbpaste \| shasum`，按 Option+T 前后对比                                                | 反馈给作者：源 app 名 + pasteboard type                                                         |
| Stanza 尝试联网    | 日志里 grep `raw.githubusercontent.com`                                                         | 确认 `translator.py` 在 import Argos 之前 patch 了 `DownloadMethod.REUSE_RESOURCES`             |
| 内存占用过高        | `ps -o rss= -p $(launchctl print gui/$(id -u)/io.github.Eim-aa.argos-translator \| awk '/pid =/ {print $3}')` | 重启服务；排查重复的长文本工作负载                                                              |

## 离线隐私

运行时只访问 `127.0.0.1`。不调 OpenAI、Google Translate、DeepL、百度、腾讯、阿里或任何云翻译 API。Stanza 已 patch 成复用打包好的 `resources.json`，不会下载 `resources_*.json`。

可自行验证：

```bash
PID=$(launchctl print gui/$(id -u)/io.github.Eim-aa.argos-translator | awk '/pid =/ {print $3}')
nettop -p "$PID"
```

## 替换为 NLLB-200-Distilled 模型

1. 在联网机器上下载或转换 NLLB-200-distilled 模型。
2. 用 `ct2-transformers-converter` 转成 CTranslate2 格式。
3. 组装成 Argos 兼容的包目录：`model/`、`sentencepiece.model`、`metadata.json`、SBD 资源。
4. 放到 `~/.local/share/argos-translator/packages/<包名>` 下。
5. 必要时改 `config.py` 里的语言代码。
6. 跑 `scripts/launchd_install.sh` 重启。
7. 跑 `scripts/test.sh` 和 `eval/run_eval.py` 验证。

## 致谢

- [Argos Translate](https://github.com/argosopentech/argos-translate)——离线翻译引擎
- [CTranslate2](https://github.com/OpenNMT/CTranslate2)——高性能推理运行时
- [Stanza](https://github.com/stanfordnlp/stanza)——句子边界识别
- [Hammerspoon](https://www.hammerspoon.org/)——macOS 自动化框架

## License

MIT，见 [LICENSE](LICENSE)。
