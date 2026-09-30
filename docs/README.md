# 句译文档

## 使用句译

- [安装、使用与问题排查](MENU_BAR_APP.md)
- [build 16 发布范围与已知限制](releases/RELEASE_0.4.0_BUILD16.md)
- [历次发布记录](releases/)（build 11–16；build 14 未公开发布）

## 参与开发

- [从源码构建与仓库结构](BUILD.md)
- [构建与发布基线](RELEASE_BASELINE.md)
- [开发记录](dev/)：原生各模块的设计、实验与审查记录，其中 [设计规范](dev/specs/README.md) 为早期规格
- [Agent 指引](../AGENTS.md)：供 AI 编程助手代用户安装句译时遵循

句译由原生 App 独立完成：双 Option、辅助功能取词、Apple Translation 或火山云端翻译、译文浮窗与朗读。不需要 Hammerspoon、Python 或后台服务；早期源码安装留下的组件由 App 检测，用户一键移除后才启用双 Option（见[使用说明](MENU_BAR_APP.md#早期组件)）。

`dev/` 中的早期 Native Lab / foundation 文档是开发阶段记录，其“默认关闭”“由 Hammerspoon 触发”等描述不代表当前发布版本。相应的 lab 代码与 `JUYI_NATIVE_*` 编译开关已于 2026-09 从仓库移除。当前用户行为以使用说明与对应构建的发布记录为准。

## 演示素材

首页使用的 [GIF](media/selection-demo.gif) 和 [MP4](media/selection-demo.mp4) 来自用户在 build 10 中真实操作的录屏，仅裁剪无关区域，未加速或替换译文。它们用于说明基本操作，不代表当前版本的性能或验收结果。

[首页截图](media/home-ready.jpg)与[设置截图](media/settings-local-cloud.jpg)是实机截图；[三步说明图](media/overview.png)是示意图。`archive/` 中的旧版 `demo.gif` 和 `render_demo.py` 属于历史素材，不应作为当前版本实录发布。
