# Spec 2：安装门槛降低

状态：**部分实现**。源码安装器已加入冲突保护、本地认证和原生 App；无终端的签名/公证 DMG/PKG 与预编译运行时仍未交付。

## 问题陈述

当前安装链对非技术用户几乎每一环都是墙：入口是终端里的 `curl | bash`；
apple 引擎要求本机 `swiftc` —— 意味着先装数 GB 的 Xcode Command Line Tools
（**整条链里最重的隐性依赖**，README 从未点明）；`git` 同样来自 CLT；
Hammerspoon 还要用户自己 `brew install`。结果是"默认离线、开箱即用"的卖点
只对已经装好开发环境的人成立。AI Agent 部署路径（AGENTS.md）同样受益于
去依赖：Agent 不必替用户跑几 GB 的 CLT 安装。

## 目标

1. 一台**没有 CLT** 的干净 macOS 15 机器能完成安装且 apple 引擎可用。
2. 提供不需要打开终端的安装入口（双击即装）。
3. 安装需要用户手动执行的步骤数从 4 步（curl、brew cask、授权、reload）
   压缩到 3 步以内（授权这一步受 TCC 限制永远省不掉）。

## 非目标

- **不消除 Homebrew/Python 依赖**：系统 python3 常为 3.9（< 3.10 下限），
  自带 Python 运行时属 .pkg/原生 app 路线（P2/总览非目标）；本版接受
  "无 brew 则先装 brew"的现状。
- **不做签名与公证**：需要付费开发者账号，列 P2 决策。
- **不改安装目标路径与 launchd 结构**。
- **不做自动更新器**：更新交互归 Spec 1 P1-2，本 spec 只保证其能判断安装形态。

## User Stories

- 作为**非技术用户**，我从没装过 Xcode 相关的任何东西，我希望装完这个工具
  离线翻译就能用，而不是先被要求下载几个 GB 的开发工具。
- 作为**非技术用户**，我想下载一个文件、双击它完成安装，而不是复制一条
  curl 命令到我从没打开过的"终端"里。
- 作为**开发者用户**，我 fork 后改了 Swift 源码，我希望安装脚本此时仍走
  本地编译而不是拉官方预编译产物。
- 作为**AI Agent**，我按 AGENTS.md 部署时希望跳过 CLT 安装这种耗时且需要
  人类确认的大依赖，直接拉取与仓库版本匹配、可校验完整性的 helper。
- 作为**维护者**，我希望用户手动从浏览器下载安装入口时，Gatekeeper 的拦截
  有一条被文档写清的出路，而不是收到"打不开"的 issue。

## 需求

### P0-1 bootstrap/install 优先使用预编译 helper

- install.sh 的 helper 环节改为三级策略：
  1. 从 GitHub Releases 下载与当前 checkout 版本匹配的
     `apple-translation-helper-<ver>-universal.tar.gz`（Spec 5 P1-1 产物），
     `shasum -a 256 -c` 校验后安装到 `bin/`；
  2. 下载或校验失败、或检测到 `apple/TranslationHelper.swift` 相对发布版本有
     本地改动（fork/开发场景）→ 回退现有 `swiftc` 本地编译；
  3. 二者皆不可行 → 维持现状（跳过 apple 引擎，提示云端可用），
     但提示文案需点明"装 Xcode Command Line Tools 后重跑可启用离线引擎"。
- 技术注意：curl 下载不写 `com.apple.quarantine`，无 Gatekeeper 弹窗；
  universal 产物需确认 lipo 合并后 ad-hoc 签名在 arm64 上有效，
  必要时发布前 `codesign -s -` 重签（验收覆盖）。

验收标准：
- Given 无 CLT 的干净 macOS 15（虚拟机验收），When 运行 bootstrap，
  Then 安装完成、`/health` 中 `engines.apple == true`、双击 ⌥ 出译文，
  全程无 CLT 安装提示、无 Gatekeeper 弹窗。
- Given 篡改下载产物（模拟损坏），Then 校验失败、自动回退或明确报错，
  绝不安装未通过校验的二进制。
- Given 本机改过 TranslationHelper.swift 且有 swiftc，Then 走本地编译。

### P0-2 去 git 依赖的获取方式

bootstrap.sh 在 `git` 不存在时改用 `curl` 下载 release tarball 解包到 DEST
（含 VERSION 信息，供 P0-1 版本匹配与 Spec 1 P1-2 判断"非 git 安装则隐藏
检查更新"）。git 存在时维持现有 clone/fast-forward 逻辑。

验收标准：无 CLT 机器（无 git）上 bootstrap 全流程成功；
tarball 安装的目录里 Spec 1 菜单不显示"检查更新"，git 安装的显示。

### P1-1 双击安装入口

- 提供 `Install-juyi.command`（内容即调用 bootstrap 的薄壳，含友好 echo），
  作为 Release 附件供下载。
- 已知限制必须写进 README 与文件同页说明：浏览器下载会带 quarantine，
  未签名 `.command` 首次运行需**右键 → 打开**确认一次（截图说明）。
  这是不买签名前的天花板，购买签名后此项自动升级（P2）。

验收标准：Safari 下载该文件 → 右键打开 → 终端窗口自动跑完安装并打印
后续步骤（授权、装 Hammerspoon），中途无需用户输入命令。

### P1-2 安装脚本代装 Hammerspoon

install.sh 检测 Hammerspoon.app 缺失且 brew 可用时，询问后执行
`brew install --cask hammerspoon` 并 `open -a Hammerspoon`（把 README 的
手动第 1、2 步收进脚本）。非交互模式（`CI=1` 或管道输入）默认跳过并提示。

### P2（记录在案，不实现）

- **签名 + 公证**（Apple Developer $99/年）：消除右键仪式、为 .pkg 铺路。
  → 开放问题，维护者决策。
- `.pkg` 安装器（pkgbuild）：真正的"下一步下一步"体验，依赖签名。
- Homebrew tap（`brew install eim-aa/tap/juyi`）：服务开发者用户的最短路径。
- 直接下载 Hammerspoon 官方 zip 免去 brew（连 brew 依赖一起消除的激进路线）。

## 成功指标

- 领先指标：干净 VM 验收矩阵全绿（有/无 CLT × 有/无 git × arm64/x86_64 抽一台）；
  安装耗时（不含语言包下载）从"CLT 下载 30+ 分钟"降到 <5 分钟。
- 滞后指标："安装失败/swiftc not found/git not found"类 issue 归零；
  README 前置要求一节可删去对 CLT 的隐性依赖。

## 开放问题

- [维护者·阻塞 P2] 是否购买 Apple Developer 账号？不买则 P1-1 的右键仪式
  即为长期形态，且 .pkg 不可行。
- [维护者·与 Spec 5 联动] 版本单一事实源：git tag vs VERSION 文件。
  tarball 路径（P0-2）无 .git，倾向 **发布产物内置 VERSION、git checkout 用
  git describe**，两 spec 需一致拍板。
- [工程·非阻塞] Releases 上是否额外发布 x86_64/arm64 单架构包以减小下载体积？
  universal 包 ~几百 KB，倾向不拆。

## 时间与依赖

硬依赖 Spec 5 P1-1（Release workflow）先行。P0 两项约 1–1.5 人日，
P1 两项约 1 人日，另加一次干净虚拟机验收（半天）。
