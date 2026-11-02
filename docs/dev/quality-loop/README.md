# 质量循环 · 使用说明

让本地的 zcode（GLM）在**隔离的 git worktree** 里，按 `RUBRIC.md` 评估句译，再做**小步、受脚本约束**的改进，早上交给你一份晨报。

Apple Design Awards 的六个维度在这里只是**评估视角**。本流程不预测、也不追求获奖。

## 它能做什么、不能做什么

- ✅ 逐条检查辅助功能、错误文案、动效守卫、术语、隐私披露等**可以从代码读出证据**的项。
- ✅ 对低风险问题（辅助功能元数据、文案、语义色、减少动态效果守卫）直接小步修复，并用 Debug/Release 构建、Swift 测试、Python 契约测试把关。
- ✅ 对布局、交互类问题出**已验证能编译、但未应用**的补丁，由你决定要不要。
- ❌ **看不到自己改动后的界面，也不会运行 App。** 所以视觉效果和 VoiceOver 实际朗读一律“未验证”。
- ❌ 不碰取词、双击 Option、密钥、翻译引擎、签名发行相关代码（脚本强制，不是提示词劝说）。
- ❌ 不会一夜之间把应用变成“获奖级”。每回合最多 2 个文件、60 行，一夜通常是个位数的小改动。你应该期待的是：一份有证据的评估、几个安全的小修复、几个待你决定的补丁、一份诚实的晨报。

## 睡前（约 10 分钟）

### 1. 建隔离的 worktree

在**你的本地句译仓库**里（路径按你的实际情况改）：

```bash
cd ~/path/to/juyi
git fetch origin claude/confident-noether-97e987
git worktree add ../juyi-quality-loop -b quality-loop/$(date +%Y%m%d) origin/claude/confident-noether-97e987
cd ../juyi-quality-loop
```

worktree 是一份独立的工作目录，**不包含**你主目录里未提交的改动、`tmp/`、`scripts/start_service.command`。zcode 只在这里面工作。

### 2. （可选但强烈建议）准备截图

没有截图，整个“视觉”维度都会是 `unknown`。花 3 分钟截这些，放进一个**仓库之外**的文件夹，例如 `~/juyi-shots/`：

| 文件名 | 内容 |
| --- | --- |
| `01-home-light.png` / `02-home-dark.png` | 首页（浅色/深色） |
| `03-onboarding-1.png` `04-onboarding-2.png` `05-onboarding-done.png` | 设置向导各步 |
| `06-popup-light.png` / `07-popup-dark.png` | 译文浮窗 |
| `08-popup-long.png` | 长段落译文（带滚动/截断说明） |
| `09-popup-error.png` | 一个失败浮窗（例如在密码框里选文字） |
| `10-menubar.png` | 菜单栏下拉菜单 |
| `11-cloud-setup.png` | 云端配置表单（**不要填入真实密钥**） |
| `12-diagnostics.png` | 诊断与帮助 |

浮窗转瞬即逝，用延时截图：先运行 `screencapture -T 6 -x ~/juyi-shots/06-popup-light.png`，6 秒内去选中文字并连按两次 Option。

> 截图会被发给模型服务商。**别拍到个人信息或真实文档内容**，用公开的英文句子。

### 3. 预检（需要联网一次）

```bash
scripts/quality_gate.sh --preflight
```

必须看到 `GATE: PASS (preflight)`。它会检查：在 worktree 里、分支名 `quality-loop/*`、macOS ≥15、Xcode 可用、git 提交身份已设置、磁盘 ≥6 GB，并建立一个**钉死版本**的 pytest/ruff 虚拟环境（一次性联网）。任何一项不过，现在修，比半夜失败好。

退出码含义：`12` 没在 worktree/分支不对；`30` 工具链缺失（输出里有具体缺什么）。

### 4. 防止电脑睡眠

```bash
caffeinate -dimsu -t 21600 &
```

保持接电源，6 小时内不休眠。合上笔记本盖子通常仍会睡眠，请保持开盖或接外接显示器。

### 5. 启动 zcode

1. 在 `juyi-quality-loop` 目录里启动 zcode，选择 GLM 模型。
2. 复制 `docs/dev/quality-loop/PROMPT.md` 中“===== 开始 =====”以下的全部内容，粘贴。
3. 粘贴前改“运行配置”三行：`SHOTS_DIR`（例如 `/Users/你的用户名/juyi-shots`，没有就留 `NONE`）、`MAX_ROUNDS`（默认 6）、`MAX_HOURS`（默认 5）。

**关于权限（这是唯一我无法替你做的安全措施）：** 我不了解 zcode 的权限配置项，所以无法给出准确设置。原则是——

- 可写目录只开放给 `juyi-quality-loop`；
- 允许自动执行的命令至少要包含：`git`（add/commit/diff/restore/apply/log/status）、`scripts/quality_gate.sh`、`grep`、`sed`、`date`、`ls`、`pwd`；
- **拒绝** `git push`、`sudo`、网络下载类命令、`security`；
- 避免使用“完全放开/跳过所有确认”的模式；如果某条命令需要人工确认而你睡着了，循环会停在那里，这是安全的失败方式，不是故障。

脚本 `quality_gate.sh` 能拦住**越界的改动**，但**拦不住模型执行一条危险命令**——后者只能靠上面的权限设置。

### 6. 离开前确认它真的开始了

等 2–3 分钟，在另一个终端里看：

```bash
cd ../juyi-quality-loop && git log --oneline | head -3
```

看到 `quality(log): ... start` 的提交，说明预检通过、账本已建立。看不到就别睡，先排查。

## 起床后

### 1. 先审计（30 秒，决定可不可信）

```bash
cd ../juyi-quality-loop
scripts/quality_gate.sh --audit
```

- `GATE: PASS (audit)`：基线之后的所有提交都没有越界、没有删测试行、没有疑似密钥。
- `FAIL (exit 10)`：有提交动了不该动的文件，或重写了历史。**不要合并**，把输出发给我看。
- `FAIL (exit 11)`：有提交里出现疑似密钥。**不要合并**，也不要推送。

### 2. 读晨报

`docs/dev/quality-loop/runs/<RUN_ID>/MORNING_REPORT.md`。重点看第 1 节“必须在真机验证的事项”和第 7 节“运行环境事实”（哪些门禁步骤真的跑过）。

### 3. 看提交

```bash
git log --oneline $(cat "$(git rev-parse --absolute-git-dir)/quality-loop-base")..HEAD
git show <sha> --stat
```

### 4. 在你的真机上验证（不能省）

晨报会列出每个提交该怎么验。要把候选版装起来试，先备份现有安装：

```bash
cp -R /Applications/句译.app ~/句译-备份.app
scripts/install_macos_app.sh
```

`install_macos_app.sh` 会退出并替换 `/Applications/句译.app`；这是你的决定，不是循环做的。装完后需要你亲手再确认辅助功能授权，并用真实的双击 Option 走一遍。不好就用备份还原。

### 5. 采纳

在你的**主仓库**里（不是 worktree）：

```bash
cd ~/path/to/juyi
git cherry-pick <sha1> <sha2> ...        # 采纳选中的 A 层提交
git apply ../juyi-quality-loop/docs/dev/quality-loop/runs/<RUN_ID>/proposals/B-01-xxx.patch   # 采纳某个 B 层补丁
```

### 6. 清理

```bash
git worktree remove ../juyi-quality-loop
git branch -D quality-loop/<日期>
```

## 出问题怎么办

| 现象 | 处理 |
| --- | --- |
| zcode 在半夜停了 | 重新粘贴同一份提示词。它会读账本，丢弃半成品，从上次的阶段继续 |
| 想立刻中止 | Ctrl-C，然后在 worktree 里 `git status`；有未提交改动就 `git restore .` |
| 晨报显示全是 blocked | 看每条 blocked 的原因。常见是构建/测试在 Release 配置下失败，或模型改了被契约测试引用的文案 |
| `--audit` 报 exit 10 | 看输出里的 `not editable:` 行，那就是越界的文件 |
| 预检在非 macOS 上失败 | 正常。预检只能在装了 Xcode 的 Mac 上通过 |

## 文件地图

| 文件 | 作用 | 循环能改吗 |
| --- | --- | --- |
| `PROMPT.md` | 交给 GLM 的主提示词 | 否 |
| `RUBRIC.md` | 评估表（条目、证据要求、评分公式） | 否 |
| `TEMPLATES.md` | 账本、评估、晨报、提交信息的格式 | 否 |
| `../../../scripts/quality_gate.sh` | 门禁：范围、密钥、构建、测试、审计 | 否 |
| `runs/<RUN_ID>/` | 本次运行的全部产出 | 是（唯一允许新建文件的地方） |

## 我没有验证的事（请知悉）

1. **门禁脚本在 macOS 上的构建与测试步骤我没有运行过**（我在 Linux 容器里，没有 Xcode）。我验证了：语法（`bash -n`）、范围/密钥/行数/测试删除/新增文件/审计/绕过门禁直接提交/历史重写等 25 个纯 git 场景的退出码、钉死版本 venv 的识别逻辑。`xcodebuild` 与 `swiftc` 那几步的命令，是照搬 `.github/workflows/ci.yml` 与 `scripts/run_swift_tests.sh` 的，但**它们在你的机器上第一次运行就是第一次验证**——这就是为什么要先跑 `--preflight`，并且最好在睡前手动跑一次 `scripts/quality_gate.sh --full`（无改动时也能跑通构建和测试，约 10–25 分钟）确认整条链路可用。
2. 我不了解 GLM 5.3 Flash 的实际能力和 zcode 的行为（是否读取 `AGENTS.md`、权限模型、是否支持长时间运行与上下文压缩）。提示词按“弱模型也不会误解”来写，并把状态全部落在账本里以便续跑，但这不能保证它一定跑完。
3. 评估表是我基于代码阅读设计的，里面的“通过条件”是合理的工程判断，不是 Apple 的官方标准。
4. 让模型对自己的修改“复评”仍有自我评分的偏差。所以晨报要求列证据，且你的真机验证是最终标准。
