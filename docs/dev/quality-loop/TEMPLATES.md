# 产出物模板

循环产出的所有文件都放在 `docs/dev/quality-loop/runs/<RUN_ID>/` 之下（`RUN_ID` 形如 `20261102-2310`）。这是门禁允许新建文件的唯一位置。本文件是只读控制文件。

目录结构：

```
runs/<RUN_ID>/
  LEDGER.md            运行账本（你的外部记忆；每个阶段与每一轮结束都要更新并提交）
  EVALUATION.md        阶段 1 的评估结果（只写一次；阶段 4 在末尾追加“复评”）
  MORNING_REPORT.md    阶段 4 的晨报
  proposals/           阶段 3 的补丁与说明（B 层）
    B-01-<id>.patch
    B-01-<id>.md
```

---

## LEDGER.md

```markdown
# LEDGER · <RUN_ID>

STATUS: RUNNING            ← 只有阶段 4 全部完成后才可改成 FINISHED
START_EPOCH: <date +%s 的输出>
MAX_ROUNDS: <配置值>
MAX_HOURS: <配置值>
SHOTS_DIR: <配置值>
BASE_COMMIT: <preflight 记录的 sha>
STRIKES: 0                 ← 门禁 exit 10 的次数；到 2 就停止
PHASE: 1                   ← 当前阶段 1/2/3/4

## 回合记录

| 回合 | 条目 | 层 | 结果 | 提交 | 备注 |
| --- | --- | --- | --- | --- | --- |
| 1 | N-04 | A | committed | abc1234 | 视觉未验证：否 |
| 2 | I-02 | A | blocked | - | Swift tests 失败：<一句话原因> |

## 已阻止（blocked）的条目
- I-02：原因 …（交给人处理）

## 下一步
- <一句话：下一轮要做什么>
```

---

## EVALUATION.md

```markdown
# 评估 · <RUN_ID>

## 证据来源
- 代码基线：<git rev-parse --short HEAD>
- 截图：<SHOTS_DIR 下的文件名清单；或 “无，视觉条目一律 unknown”>
- 截图是否过期：<是/否；理由>

## 条目结果
| ID | 结果 | 严重度 | 层 | 证据 | 修复建议（仅 fail） |
| --- | --- | --- | --- | --- | --- |
| N-01 | pass | - | - | `macos/JuyiMenuBar.swift:1415` `.accessibilityLabel(progressAccessibilityLabel)` … | - |
| N-04 | fail | 2 | A | 云端验证完成时无 announcement（`configureCloud` 之后无 `NSAccessibility.post`） | 在成功/失败分支各加一次播报 |
| V-01 | unknown | - | B | 无截图 | - |

## 维度汇总（score / coverage，不合成总分）
| 维度 | score | coverage | 缺什么证据 |
| --- | --- | --- | --- |
| Interaction | 0.xx | 0.xx | … |
| Inclusivity | … | … | … |
| Visuals and Graphics | … | … | … |
| Delight and Fun | … | … | … |
| Innovation | … | … | … |

## R-01 间歇性“不支持”假设
1. 假设：… ｜ 代码：`path:line` ｜ 置信度：中 ｜ 真机验证方法：…

## R-02 文档与代码一致性
- 事实：… 位置：…

## X-02 想法（不实现，至多 3 条）
1. …
```

---

## 提交信息格式（每个代码提交）

```
quality(<条目ID>): <一句话说明做了什么>

层: A
改动: <文件名> +<增>/-<删>
验证: 编译通过、Swift 测试通过、契约测试通过
未验证: 视觉效果 / VoiceOver 实际朗读 / 真机行为   ← 如实写，不得省略
```

只改日志的提交：`quality(log): <RUN_ID> <阶段或回合>`。

---

## B 层提案（proposals/）

`B-01-<id>.md`：

```markdown
# B-01 · <条目ID> · <标题>
- 为什么：<对应的 fail 证据>
- 补丁：`B-01-<id>.patch`（已用 `git apply --check` 与 `scripts/quality_gate.sh --full --max-lines 400` 验证，当前未应用）
- 应用方法：`git apply docs/dev/quality-loop/runs/<RUN_ID>/proposals/B-01-<id>.patch`
- 风险：<布局/焦点/动画的哪些方面可能出问题>
- 需要你在真机上看什么：<具体步骤>
```

---

## MORNING_REPORT.md

```markdown
# 晨报 · <RUN_ID>

**一句话**：<N 个提交 / M 个被阻止 / K 个提案；停止原因：…>

## 0. 先做这一步
在 worktree 里运行：`scripts/quality_gate.sh --audit`，预期输出 `GATE: PASS (audit)`。
本次运行内我自己执行的结果：<粘贴 audit 的最后一行>

## 1. 必须在真机验证的事项（按提交列出）
| 提交 | 条目 | 你要做什么 | 期望看到 |
| --- | --- | --- | --- |
| abc1234 | N-04 | 打开 VoiceOver（⌘F5），走一遍云端配置，点“保存并验证” | 验证成功/失败各被朗读一次 |

> 所有提交的状态都是“编译通过＋测试通过，视觉与真机行为未验证”。

## 2. 提交清单
| sha | 条目 | 文件 | 行数 | 做了什么 |

## 3. 评估前后对比
| 维度 | score 前→后 | coverage 前→后 |
变化的条目：<ID: fail→pass …>

## 4. 被阻止的条目
- <ID>：<原因＋失败输出里最关键的一行>

## 5. B 层提案
- <B-01：标题 ｜ 风险 ｜ 补丁路径>

## 6. 需要你判断或亲自处理的事项（C 层）
- R-01 假设（附置信度）
- R-02 事实
- <其它>

## 7. 运行环境事实
- macOS / Xcode 版本、用了哪些截图、门禁各步骤是否都实际执行、哪些步骤被跳过及原因
- 用时：<分钟>；回合数：<n>/<MAX_ROUNDS>

## 8. 我没有做、也做不到的事
- 没有看到任何修改后的界面
- 没有在真机上运行 App
- 没有验证 VoiceOver 的实际朗读
```
