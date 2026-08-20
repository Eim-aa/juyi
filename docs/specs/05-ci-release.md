# Spec 5：CI 与发布流水线

状态：**CI 检查已实现；Release 发布未完成**。当前 workflow 覆盖 Python 测试/静态检查、Swift 编译与策略测试、Lua/Bash 语法；Developer ID、Apple 公证和 Release 产物仍是发布阻断。

## 问题陈述

仓库目前提交层面零保护：所有测试（smoke.py、test_matrix.py）都要求本机跑着真服务、
真引擎，PR 阶段连"Python 能不能 import、Swift 能不能编译、Lua 有没有语法错"都无人把关
——历史上 a92e221 修的 `hs.http.asyncGet` 签名错误（曾导致整个配置加载中止）正是
这类本可被静态检查拦下的问题。同时 Spec 2 需要"预编译 helper"作为分发产物，
手工在本机编译上传不可持续。

## 目标

1. 每个 PR 自动获得：Python 静态检查 + 离线单测、Swift 编译检查、Lua 静态检查，
   任一失败即红。
2. 打 tag 即自动产出可分发的 helper 二进制（含校验和），Spec 2 直接消费。
3. `translator.py` 的核心决策逻辑（引擎解析回退链、输入策略）具备不依赖任何引擎的
   离线单测覆盖。

## 非目标

- **不做端到端翻译的 CI 测试**：apple 引擎需要语言包（CI 上无法交互确认系统下载弹窗），
  volc 引擎需要真实计费密钥。二者在 CI 均不可行/不值得，e2e 保留为本机
  `scripts/test.sh` 的职责，CI 不承诺。
- **不引入重型测试框架生态**：pytest + ruff + luacheck 三件，不加 coverage 门槛、
  不加 pre-commit 强制。
- **不做多 macOS 版本矩阵**：只跑 macos-15 runner（产品最低支持线）。
- **不做签名/公证**：Release 产物为 ad-hoc 签名（swiftc 默认），公证归 Spec 2 的
  P2 决策（需要付费开发者账号）。

## User Stories

- 作为**贡献者**，我提 PR 后几分钟内能看到我的 Lua/Python/Swift 改动有没有低级错误，
  不需要维护者在自己机器上手工发现。
- 作为**维护者**，我改动 `translate()` 的回退链时，有单测告诉我"volc 无凭证时请求
  volc 应回退 apple 并带 warning"这类契约没被改破。
- 作为**维护者**，我打一个 `v0.x` tag，几分钟后 Release 页面上出现带 shasum 的
  helper 产物，不需要我本机编译上传。
- 作为**AI Agent**（Spec 2 场景），我能从 GitHub Releases 拉到与仓库版本对应的
  预编译 helper 并校验完整性。

## 需求

### P0-1 前置重构：抽取可测纯函数

把 translator.py 中内联在 `translate()` 里的决策逻辑抽为纯函数（无 I/O、无全局态）：

- `resolve_engine(requested, default, volc_ok, apple_ok) -> (engine, warnings)`
  —— 现 109–129 行的映射与双向回退链。
- 输入策略函数：规范化换行、截断（与 Spec 3 P0-2 后的行为一致）、
  `_cjk_ratio` / `_letter_count` 判定（已是纯函数，补测试即可）。

验收标准：重构后 smoke.py 全绿；`translate()` 主体只剩编排。
（与 Spec 3 P1-4 的 `_run_engine` 去重同 PR 完成最省事。）

### P0-2 tests/ 离线单测

pytest，至少覆盖：

- 引擎解析矩阵：argos→apple 映射、volc 无凭证回退 apple、apple 不可用回退 volc、
  双不可用、非法引擎名 → 各自的 engine 与 warnings 断言。
- 输入策略：CJK 比例阈值两侧、纯标点 skip、CRLF 规范化、截断边界（恰好 MAX、MAX+1）。
- config `_load_env_file`：注释行、空行、无 `=` 行、带引号值（Spec 3 P0-3 的行为）。
- volc_engine 签名函数：给定固定输入断言 canonical request / signature 的确定性
  （防手滑改坏签名算法；不发真实请求）。

验收标准：`venv/bin/pytest tests/ -q` 本机与 CI 均通过，全程无网络、无 helper。

### P0-3 GitHub Actions：PR 检查 workflow

`.github/workflows/ci.yml`，触发于 push/PR：

| Job | Runner | 内容 |
| --- | ------ | ---- |
| python | macos-15 | `pip install -r requirements.txt ruff pytest` → `ruff check .` → `python -m compileall *.py scripts/*.py` → `pytest tests/` |
| swift | macos-15 | `swiftc -typecheck apple/TranslationHelper.swift` |
| lua | ubuntu-latest | `luacheck hammerspoon/ --std lua54 --globals hs`（配 `.luacheckrc`） |

验收标准：
- 三个 job 在当前 main 上全绿（存量 ruff 告警在同 PR 内修掉或写入豁免配置）。
- 故意引入一个 Lua 语法错误 / 未定义 Python 名字 / Swift 类型错误的测试 PR 均变红。

### P1-1 Release workflow：helper 产物

`.github/workflows/release.yml`，触发于 `v*` tag：

- macos-15 runner 上构建 **universal 二进制**
  （`swiftc -O` 分别产出 arm64 与 x86_64，`lipo -create` 合并——Intel Mac 仍在
  macOS 15 支持线内）。
- 产物：`apple-translation-helper-<tag>-universal.tar.gz` + `SHA256SUMS`，
  上传到该 tag 的 GitHub Release。
- 仓库增加 `VERSION` 文件（或以 git tag 为准，见开放问题），供 Spec 2 的
  bootstrap 匹配"checkout 版本 ↔ 产物版本"。

验收标准：打测试 tag 后 Release 页面出现产物；本机下载解包、`shasum -c` 通过、
`file` 显示两种架构、在 macOS 15 上 `--status` 正常输出。

### P1-2 README 徽章

CI 状态徽章加入根 README 徽章行。

### P2（记录在案，不实现）

- luacheck 之上引入 Hammerspoon API stub 类型检查（lua-language-server CI 化）。
- CI 缓存 pip/swift 模块以提速（当前依赖极轻，收益小）。

## 成功指标

- 领先指标：main 分支徽章常绿；引入故障的金丝雀 PR 三类检查均能拦截。
- 滞后指标：此后合入 main 的回归类 bug（能被静态检查/单测覆盖的类型）为零；
  Spec 2 上线后预编译产物的下载校验失败反馈为零。

## 开放问题

- [维护者] 版本源以 git tag 为单一事实还是引入 `VERSION` 文件？
  倾向 git tag（少一处同步点），bootstrap 侧用 `git describe --tags` 取值；
  但若 Spec 2 采用 tarball 分发（无 .git），则需要 VERSION 文件随包走——
  **此问题需与 Spec 2 的分发形态一起拍板**（阻塞 P1-1 的版本匹配设计，不阻塞 P0）。
- [维护者] ruff 规则集从默认起步还是直接上 `--select I,E,F,W,UP`？默认起步即可，不阻塞。

## 时间与依赖

P0 三项 ≤1.5 人日（重构与 Spec 3 P1-4 合 PR 可摊薄）；P1-1 约半天。
Spec 2 的 P0 依赖本 spec 的 P1-1 产物，排期时注意先后。
