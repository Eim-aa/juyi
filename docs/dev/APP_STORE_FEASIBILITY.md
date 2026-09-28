# App Store 可行性 · 2026-09-25

结论：当前版本先完成 GitHub 的 Developer ID 签名、公证分发；不能把同一个 App 直接上传 Mac App Store，也不能承诺现有跨 App 双 Option 体验能原样保留。

Apple 要求 Mac App Store App 启用 App Sandbox，并明确把辅助应用使用 Accessibility API、向任意 App 发送 Apple Events、修改其他 App 偏好等列为沙盒限制。见 [Apple 的沙盒说明](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)及[配置要求](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)。

本工程 `Config/Shared.xcconfig` 明确 `ENABLE_APP_SANDBOX = NO`。主体验依赖跨 App AX 选区读取，同时管理 Hammerspoon 配置和用户级后台组件。因此，切换一个配置开关或换证书不构成商店适配，也不能靠私有 API 或隐藏外部辅助组件绕过审核。

如果未来需要商店版，应先验证合规的 Share Extension、服务菜单或用户主动粘贴入口。这会改变产品交互及支持范围，需要单独确认产品取舍，再做实现和审核；当前没有擅自删掉已验收的双 Option 链路。正式签名、公证可解决站外分发信任问题，不替代 App Store 审核。
