# Spec 3：错误可见性与健壮性修复

状态：**历史验收记录，已实现**（2026-07-13；P0 全部 + P1 全部，P2 按规格仅记录）· 依赖：无。文中 `volc.env` 配置方式已被原生 App + macOS 钥匙串取代，当前行为以 [`docs/MENU_BAR_APP.md`](../MENU_BAR_APP.md) 和代码为准。

## 问题陈述

引擎调用失败（`apple_error` / `volc_error` / `no_engine_available`）时，服务端把原文回显在
`result` 里，而 Lua 客户端只处理 `empty_input` 和 `src_lang_mismatch` 两种错误
（hammerspoon/argos-translator.lua:314 起），于是浮窗把**英文原文当译文展示**，小字还标注
"来自 苹果端上翻译 · N ms"。用户唯一的感知是"这工具翻得跟没翻一样"，而 README 故障排查表
承诺的"看浮窗里的 volc_error 提示"实际不存在。对一个以"开箱即用"为卖点的工具，
**故障不可见是最伤信任的缺陷**：用户不会去翻 JSONL 日志，只会卸载。
同批打包若干健壮性小修：它们单独都不值一份 spec，但都属于"沉默地做错事"这一类。

## 目标

1. 引擎故障时，用户 100% 能在浮窗里看到"出错了 + 错在哪 + 怎么办"，不再有静默回显。
2. 译文内容零污染：任何服务端附加的标记（截断等）只存在于元数据，不进翻译正文。
3. 常见配置失误（volc.env 带引号）不再产生难以归因的签名 401。
4. 故障可排查：helper 的框架级报错能在日志里找到，而不是只有一个 timeout。

## 非目标

- **不改错误的语义与回退链**：服务端"失败时回显原文 + error 字段"的契约保持不变，
  本 spec 只修客户端展示与正文污染。
- **不做错误上报/遥测**：本地工具，日志留在本机。
- **不重做浮窗视觉**：错误态复用现有 canvas，只加样式区分；整体 UI 改进归 Spec 1。
- **不解决 `cached` 探测的并发竞态**：单人本机使用影响可忽略，记录在案即可（P2）。

## User Stories

- 作为**非技术用户**，云端 Key 配错时我想在浮窗里直接看到"云端翻译出错：签名无效"
  之类的提示，而不是看到一句没翻的英文，这样我才知道该去检查 Key 而不是怀疑选中失败。
- 作为**开发者用户**，语言包没装导致 apple 引擎超时时，我想在日志里看到框架的原始报错，
  这样不用瞎猜是 helper 死了还是系统弹窗卡住了。
- 作为**开发者用户**，我在 volc.env 里习惯性给值加了引号，我希望工具照常工作
  （或至少报错指向引号），而不是收到一个和引号毫无关联的 401。
- 作为**非技术用户**，选中超长文本时我想拿到干净的译文加"已截断"标记，
  而不是译文尾部混着一句机器翻译出来的"…[被截断]"。
- 作为**维护者**，我想让 README 故障排查表描述的行为与代码一致，不再收到
  "文档说浮窗会提示但没有"的 issue。

## 需求

### P0-1 客户端展示引擎错误

浮窗回调里，`parsed.error` 非空且不属于已处理的 `empty_input` / `src_lang_mismatch` 时，
进入错误展示分支：正文为错误标题（映射表：`apple_error`→"苹果端上翻译出错"、
`volc_error`→"云端翻译出错"、`no_engine_available`→"没有可用的翻译引擎"，
未知值原样展示），副标题为 `warnings[1]`（截到 120 字符）+ 一行修复指引
（如 `volc_error` → "检查 volc.env 的 AK/SK"）。错误正文用视觉可区分的样式（前缀 ⚠️ 即可）。

验收标准：
- Given 服务端返回 `{"error":"volc_error","result":"<原文>","warnings":["volc http 401: ..."]}`，
  When 浮窗更新，Then 正文显示"⚠️ 云端翻译出错"而非原文，副标题含 `volc http 401`。
- Given `error == "apple_error"` 且 warnings 为空，Then 副标题至少含修复指引，不显示 nil。
- Given 翻译成功（error 为空），Then 展示行为与现状完全一致（回归不变）。
- README 故障排查表更新为与实际浮窗文案一致。
- `parsed.skipped == true`（如纯标点输入）不走错误分支，维持现有"未翻译"标注。

### P0-2 截断标记退出正文

translator.py:141 不再把 `"…[truncated]"` 拼进送引擎的文本；截断只体现在
`truncated: true` 与 `input_truncated` warning。客户端已有"已截断"标注，无需改动。

验收标准：
- Given 输入 6000 字符，When 翻译完成，Then 送引擎的文本恰为前 `MAX_INPUT_CHARS` 字符，
  译文中不含"截断/truncated"字样，响应 `truncated == true`。
- scripts/smoke.py 的 `huge_6000` 用例补充断言：`"截断" not in result`。

### P0-3 volc.env 解析剥引号

config.py `_load_env_file` 对值做一层处理：剥除首尾成对的 `"` 或 `'`。

验收标准：
- `VOLC_ACCESS_KEY="abc"`、`'abc'`、`abc` 三种写法解析结果一致为 `abc`。
- 值内部的引号（不成对/不在首尾）不受影响。

### P1-1 helper stderr 落日志

apple_engine.py 不再把 helper 的 stderr 指向 DEVNULL，改为追加写入
`~/Library/Logs/argos-translator-helper.log`（打开失败则退回 DEVNULL，不影响主流程）。
该文件纳入 uninstall 清理清单（与 Spec 4 对齐）。

验收标准：Given 语言包未安装导致框架报错，When 请求 apple 引擎，
Then helper 日志中能看到框架错误原文，服务端行为不变。

### P1-2 Hammerspoon 侧日志轮转

`M.start()` 时检查 `argos-translator-hs.log`，超过 5 MB 则重命名为 `.1`（覆盖旧 `.1`）。

### P1-3 /translate 强制 Content-Type

`Content-Type` 非 `application/json` 的 POST 返回 415。目的：跨站 simple request
（浏览器网页无预检的 `text/plain` POST）无法再触发翻译烧云端配额。

验收标准：
- `curl -X POST -H 'Content-Type: text/plain' -d '{"text":"hi"}'` → 415。
- 现有客户端（Lua、smoke.py、test_matrix.py、run_eval.py、AGENTS.md 里的 curl 示例）
  全部已带 JSON Content-Type，回归全绿。

### P1-4 `translate()` 引擎分支去重

translator.py:165–200 两段几乎相同的 try/except + cache 探测 + 延迟统计收敛为
`_run_engine(eng, text)`。行为不变的纯重构，为 Spec 5 的单测抽取铺路，
也让 README"新增引擎只写一个函数"的宣传成立。

验收标准：重构前后 smoke.py 全部用例输出一致（含 cached / elapsed / warnings 字段结构）。

### P1-5 浮窗高度估算修正

buildCanvas 现用"自然宽度 ÷ 可用宽度"估行数再乘单行高，译文含换行时双重放大导致弹窗过高。
改为按换行拆段分别估算，或采用 `hs.canvas:minimumTextSize` 类 API 实测。

验收标准：对"两段各一行短文本 + 一段需折行的长文本"的译文，弹窗高度与内容目测贴合，
无超过一行高度的空白。

### P2（记录在案，不实现）

- `cached` 探测的并发竞态：改为自管缓存字典可精确，收益低。
- 语言对配置漂移：apple helper 硬编码 en→zh-Hans，config 的 `SRC_LANG/TGT_LANG`
  只对 volc 生效。既然产品定位锁定英→中（见总览非目标），倾向在 config.py 注释
  声明这两个常量仅影响 volc，而非把 helper 参数化。→ 待维护者拍板，见开放问题。

## 成功指标

- 领先指标：新增 smoke 用例（错误展示、截断纯净、415）全绿；
  故障注入测试（错误 AK/SK）下浮窗必现错误提示，人工验收通过。
- 滞后指标：本机 JSONL 日志中 `translate_done` 带 error 的事件均能对应一次
  用户可见的错误展示（抽查）；GitHub 不再出现"翻译没反应/原文照抄"类 issue。

## 开放问题

- [维护者] 语言对策略二选一：helper 增加 `--source/--target` 参数化，还是 config 注释
  声明仅 volc 生效？（不阻塞本 spec 其余条目；默认后者。）
- [维护者] 错误浮窗是否需要点击直达日志文件（`open ~/Library/Logs/...`）？
  倾向留给 Spec 1 的菜单栏"打开日志"，此处不做。

## 时间与依赖

无外部依赖。P0 三项 ≤1 人日，P1 五项合计 1–2 人日。建议与 Spec 4 合成一个
"correctness & cleanup" 里程碑先行发布，因为 Spec 1 的错误态 UI 建立在 P0-1 之上。
