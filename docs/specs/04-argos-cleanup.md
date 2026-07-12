# Spec 4：Argos 残留清理

状态：**已实现**（2026-07-13；P0 全部 + P1-1 取"删 § 引用改一句话注释"路径，P2 按规格仅记录）· 依赖：无

## 问题陈述

34dbe8f 移除 Argos 引擎的重构没有扫尾：死配置常量、恒真的 `/health` 字段、
plist 里无人消费的环境变量、按"要下模型"设计的 1 GB 磁盘检查，
以及一个还在问"要不要删模型包"、却**不清理 API 密钥文件与 init.lua 挂钩**的 uninstall.sh。
对新读者这些残留是理解噪音；对用户，卸载不彻底意味着密钥文件（volc.env）在
"以为已卸载"的机器上继续存在——这是安全卫生问题，不只是洁癖。

## 目标

1. 仓库内零死引用：删除的引擎不再以任何配置、字段、注释、环境变量的形式存在。
2. `/health` 的每个字段都反映真实状态，诊断脚本断言与之同步。
3. 卸载后系统无残留（或残留均为用户明确选择保留的），卸载提示与实际行为一致。

## 非目标

- **不改目录名/服务名**：`~/.local/share/argos-translator` 与 launchd label 改名为 juyi
  是高成本迁移（已装用户的路径兼容、launchd 迁移逻辑），列入 P2 记录，本版不做。
- **不新增 /health 能力**：只删假字段、对齐既有字段，helper 存活探测等增强归 Spec 1 消费时再议。
- **不动 volc.env 的格式与位置**。

## User Stories

- 作为**贡献者**，读 config.py 时我看到的每个常量都有消费方，不用 grep 半天确认
  `LONG_INPUT_CHARS` 是不是我漏了什么。
- 作为**用户**，跑完 uninstall.sh 后我的机器上不再有这个工具的服务、日志、挂钩和
  （经我确认后的）密钥文件；提示里不会出现一个已不存在的"模型包"。
- 作为**开发者用户**，`curl /health` 返回的字段我可以照单全信，不会被一个
  永远为 true 的 `model_loaded` 误导排查方向。
- 作为**AI Agent**，AGENTS.md/README 引用的命令与字段和实际行为一致，我不会
  按文档断言一个不存在的行为然后向人类误报。

## 需求

### P0-1 删除死配置与 legacy 字段

- config.py：删 `LONG_INPUT_CHARS`、`LONG_INPUT_WORDS`、`VENV`；
  注释中"§6.1/§6.5/§6.6/§8"的文档引用一并处理（见开放问题）。
- server.py `/health`：删 `model_loaded`、`warmup_ms`；translator.py 删 `warmup_ms`
  字段及 lifespan 里对应日志字段。
- scripts/test_matrix.py：同 PR 内同步删除对 `model_loaded` 的两处断言
  （wait_for_health 与 GET /health 检查改为断言 `ok == true` 且 `engines` 存在）。

验收标准：
- `grep -rn "LONG_INPUT\|model_loaded\|warmup_ms" --include='*.py' --include='*.sh' --include='*.lua'`
  在仓库内（排除 venv）零命中。
- smoke.py 与 test_matrix.py 对运行中的服务全绿。

### P0-2 launchd plist 清理

模板中删除 `ARGOS_PACKAGES_DIR` 与 `OMP_NUM_THREADS`（CTranslate2 残留，无消费方）。
`PATH` 保留。

验收标准：`launchd_install.sh` 重装后服务正常、`launchctl print` 环境变量中无上述两项。

### P0-3 install.sh 磁盘检查校准

1 GB 门槛（模型时代）调整为 200 MB（venv + 余量），报错文案同步。

### P0-4 uninstall.sh 重写

行为清单（按序执行，每步幂等）：

1. bootout launchd 服务、删 plist（现状保留）。
2. 删 venv、`bin/`（编译产物）、`$ROOT/logs` 符号链接。
3. 删日志：`argos-translator.{out,err}.log`、`argos-translator.log*`、
   `argos-translator-hs.log*`、helper 日志（与 Spec 3 P1-1 对齐）。
4. 摘除 Hammerspoon 挂钩：删 `~/.hammerspoon/argos-translator.lua` 符号链接；
   从 `~/.hammerspoon/init.lua` 中删除 `require("argos-translator")` 行
   （只删完全匹配行，其余内容不动）。
5. **交互确认（默认 N）**：删除 `~/.config/argos-translator/`
   （提示明确点名"包含火山 API 密钥 volc.env 与引擎选择状态"）。
6. 删除"模型包"提问整段移除（packages/ 若存在则并入第 5 步之外无条件删除——
   它只可能是 pre-apple 时代残留，且 .gitignore 已声明其为 legacy）。
7. 结尾提示：仓库目录本身与 Hammerspoon.app 需要用户自行删除（打印两条命令）。

验收标准：
- Given 一台完整安装过（含 volc.env、跑过翻译产生日志）的机器，
  When 运行 uninstall.sh 并对密钥问题答 N，
  Then `launchctl print` 无服务、`~/.hammerspoon/init.lua` 无 require 行、
  日志与 venv/bin 均不存在、`~/.config/argos-translator/volc.env` 仍在。
- 答 Y 时 `~/.config/argos-translator/` 整目录消失。
- 对同一台机器连续运行两次不报错（幂等）。
- 输出中不出现"model package"字样。

### P1-1 设计文档引用处置

config.py 注释引用的分节设计文档（§6.x/§8）不在仓库中。二选一：
把该文档整理进 `docs/design.md` 并修正引用；或删除所有 § 引用、就地写明一句话理由
（如"HTTP loopback 实测优于 UDS，见 scripts/bench_ipc.py"）。→ 见开放问题。

### P2（记录在案，不实现）

- 目录/服务/仓库名统一为 juyi：需要迁移方案（沿用 launchd_install.sh 已有的
  LEGACY_LABEL 先例），等一个值得破坏兼容的大版本再做。
- README 中 pot-desktop 对比表等内容随上述改动顺检一遍（放入常规 docs 维护）。

## 成功指标

- 领先指标：上述 grep 零命中；全新机器 install → smoke → uninstall 全流程
  人工走查通过，残留清单为空。
- 滞后指标：不再出现"卸载后还在跑/密钥还在"类反馈；新贡献者提问中不再出现死常量。

## 开放问题

- [维护者] §6.x 设计文档原稿是否还在（个人笔记？）？在 → 入库 docs/design.md；
  不在 → 删引用改一句话注释。不阻塞其他条目。
- [维护者] uninstall 是否顺带 `brew uninstall --cask hammerspoon`？
  倾向不做（Hammerspoon 可能被用户的其他配置使用），仅打印提示。

## 时间与依赖

无依赖，可立即开工。与 Spec 3 合并为一个里程碑（一次发版、一次 README 更新）。
注意 P0-1 的 /health 字段变更与 test_matrix 断言必须同 PR，避免中间态 CI/诊断挂掉。
