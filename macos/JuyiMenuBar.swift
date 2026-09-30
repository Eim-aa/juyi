import AppKit
import Combine
import CoreGraphics
import CryptoKit
import Darwin
import ServiceManagement
import SwiftUI

private let appBundleIdentifier = "io.github.Eim-aa.Juyi"
private let fallbackLoginItemLabel = "io.github.Eim-aa.Juyi.login-item"
private let fallbackLoginItemExecutable = "/Applications/句译.app/Contents/MacOS/Juyi"
private let volcKeychainService = "io.github.Eim-aa.juyi.volc"
private let volcKeychainAccount = "volc"
/// The single source of the engine choice.
private let selectedEngineDefaultsKey = "selectedEngine"
/// The pause switch. Quitting writes `true`, so a relaunch stays paused until
/// the user resumes. Migrated once from the legacy `hs-paused` file.
private let pausedDefaultsKey = "translationPaused"
/// When the early shortcut module was removed; a module host launched
/// before this may still run it (see LegacyComponentCleanup).
private let legacyCleanupDateDefaultsKey = "legacyModuleRemovedAt"
private let quitMenuTitle = "退出句译"

private struct CloudCredentials: Codable, Equatable, Sendable {
    let accessKey: String
    let secretKey: String

    enum CodingKeys: String, CodingKey {
        case accessKey = "access_key"
        case secretKey = "secret_key"
    }
}

private enum CloudCredentialRead: Equatable, Sendable {
    case found(CloudCredentials)
    case notFound
    case invalid
    case unavailable
}

enum LoginItemState: Equatable {
    case enabled, notRegistered, requiresApproval, notFound
}

private enum LoginItemBackend {
    case serviceManagement, launchAgent
}

private final class BoundedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        // External status commands should remain small. Keep draining the pipe
        // after this cap so an unexpected child cannot deadlock or exhaust RAM.
        let remaining = max(0, 1_048_576 - storage.count)
        if remaining > 0 { storage.append(contentsOf: data.prefix(remaining)) }
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var selectedEngine = "apple"
    @Published private(set) var testing = false
    @Published private(set) var paused = false
    @Published private(set) var hasChecked = false
    @Published var testResult = ""
    @Published var testDetail = ""
    @Published var notice = ""
    @Published var showCloudSetup = false {
        didSet { if showCloudSetup != oldValue { refreshContextChanged(sheetOpened: showCloudSetup) } }
    }
    @Published var showDiagnostics = false {
        didSet {
            guard showDiagnostics != oldValue else { return }
            // The login-item toggle lives in this sheet; query ServiceManagement
            // only while it can be seen.
            if showDiagnostics { refreshLoginItemState() }
            refreshContextChanged(sheetOpened: showDiagnostics)
        }
    }
    @Published var showSupportInfo = false
    @Published var cloudBusy = false
    @Published var cloudError = ""
    @Published var onboardingPresented = false
    @Published var onboardingScreen: OnboardingScreen = .welcome
    @Published private(set) var loginItemState: LoginItemState = .notRegistered
    @Published private(set) var loginItemBusy = false
    @Published private(set) var loginItemNotice = ""
    @Published var permissionTroubleshooting = false
    @Published var practiceTroubleshooting = false
    @Published private(set) var legacyState: LegacyComponentState = .clean
    @Published private(set) var legacyCleanupBusy = false

    var onChange: (() -> Void)?
    private var timer: Timer?
    private var timerInterval: TimeInterval?
    private var applicationActive = false
    private var activationLoginItemMigrationChecked = false
    private var nativeStateObservation: AnyCancellable?
    private var onboardingPreservesCompletion = false
    private var loginItemMigrationInProgress = false
    private var loginItemBackend: LoginItemBackend = .serviceManagement
    private var localCloudCredentialFingerprint: String?
    private let loginItemRegistrationKey = "loginItemInitialRegistrationAttempted"
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var fallbackLoginItemPlist: URL { home.appendingPathComponent("Library/LaunchAgents/\(fallbackLoginItemLabel).plist") }
    private var bundleIsInApplicationsFolder: Bool {
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath()
        let userApplications = home.appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        return bundleParent.path == "/Applications"
            || bundleParent.path == userApplications.path
    }
    private var onboardingDisposition: OnboardingDisposition {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "onboardingDisposition"), let value = OnboardingDisposition(rawValue: raw) else { return .neverStarted }
            return value
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "onboardingDisposition")
            UserDefaults.standard.set(OnboardingPolicy.currentVersion, forKey: "onboardingVersion")
        }
    }
    private var cloudVerified: Bool {
        get {
            guard let fingerprint = localCloudCredentialFingerprint else { return false }
            return UserDefaults.standard.string(forKey: "cloudVerifiedFingerprint") == fingerprint
        }
        set {
            if newValue, let fingerprint = localCloudCredentialFingerprint {
                UserDefaults.standard.set(fingerprint, forKey: "cloudVerifiedFingerprint")
            } else { UserDefaults.standard.removeObject(forKey: "cloudVerifiedFingerprint") }
        }
    }

    init() {
        // Keychain commands are deliberately deferred so startup never waits
        // on `security` on MainActor. The native cloud engine reads the
        // credential through the same bounded `security` wrapper, off the
        // main actor, only when it needs it.
        VolcTranslationEngine.shared.credentialProvider = {
            await Task.detached { AppModel.readVolcEngineCredentials() }.value
        }
        migrateOnboardingState()
        let defaults = UserDefaults.standard
        // One-time migration of the legacy `hs-paused` switch; afterwards
        // UserDefaults is the only pause source.
        if defaults.object(forKey: pausedDefaultsKey) == nil {
            defaults.set(LegacyComponentCleanup.legacyPauseState(home: home) ?? false, forKey: pausedDefaultsKey)
        }
        paused = defaults.bool(forKey: pausedDefaultsKey)
        // UserDefaults is the engine source of truth. An explicit legacy
        // choice is migrated once; absent any explicit choice nothing is
        // persisted and the privacy-safe default applies.
        let storedEngine = Self.validEngine(defaults.string(forKey: selectedEngineDefaultsKey))
        var legacyEngine: String?
        var environmentEngine: String?
        if storedEngine == nil {
            let legacy = LegacyComponentCleanup.legacyEngineChoices(home: home)
            legacyEngine = Self.validEngine(legacy.explicit)
            environmentEngine = legacy.environment
            if let legacyEngine { defaults.set(legacyEngine, forKey: selectedEngineDefaultsKey) }
        }
        selectedEngine = OnboardingPolicy.preferredEngine(
            explicitEngine: storedEngine ?? legacyEngine,
            environmentEngine: environmentEngine
        )
        // Fail-closed before the first activation: early components keep the
        // native chain disabled until the user removes them.
        refreshLegacyComponents()
        switch onboardingDisposition {
        case .neverStarted:
            onboardingScreen = .welcome; onboardingPresented = true
        case .inProgress:
            onboardingScreen = .permission; onboardingPresented = true
        case .deferred, .completed:
            onboardingPresented = false
        }
        configureDefaultLoginItemIfNeeded()
        // Hold the cloud-operation lock until the stored credential has been
        // read, so the setup UI never shows a stale "no key" state.
        cloudBusy = true
        Task {
            localCloudCredentialFingerprint = credentialFingerprint(
                await readCloudCredentialsOffMainActor()
            )
            cloudBusy = false
            await refresh()
            if onboardingPresented && onboardingDisposition == .inProgress {
                onboardingScreen = firstIncompleteScreen()
            }
        }
        scheduleRefreshTimer()
        nativeStateObservation = NativeProductionTranslationCoordinator.shared
            .objectWillChange.sink { [weak self] _ in
                Task { @MainActor in
                    self?.objectWillChange.send()
                    self?.onChange?()
                }
            }
    }

    private var refreshContext: AppRefreshContext {
        AppRefreshContext(
            cloudSetupVisible: showCloudSetup,
            diagnosticsVisible: showDiagnostics,
            applicationActive: applicationActive
        )
    }

    /// Reschedules the periodic refresh only when its cadence changes.
    private func scheduleRefreshTimer() {
        let interval = AppRefreshPolicy.interval(refreshContext)
        guard timer == nil || timerInterval != interval else { return }
        timer?.invalidate()
        timerInterval = interval
        let next = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        next.tolerance = interval / 10
        timer = next
    }

    private func refreshContextChanged(sheetOpened: Bool) {
        scheduleRefreshTimer()
        if sheetOpened { Task { await refresh() } }
    }

    func applicationResignedActive() {
        applicationActive = false
        scheduleRefreshTimer()
    }

    var userPaused: Bool { paused }
    var cloudConfigExists: Bool { localCloudCredentialFingerprint != nil }
    /// Both engines share the native chain, so the shortcut is ready exactly
    /// when that chain is active.
    var hotkeyReady: Bool { NativeProductionTranslationCoordinator.shared.isEnabled }
    var onboardingCompleted: Bool { onboardingDisposition == .completed }
    var ready: Bool {
        !paused && NativeProductionTranslationCoordinator.shared.isEnabled
    }
    /// `requiresApproval` still represents an active user request. Keeping the
    /// toggle on lets the user cancel that request with `unregister()`.
    var loginItemEnabled: Bool {
        loginItemState == .enabled || loginItemState == .requiresApproval
    }
    var loginItemStateTitle: String {
        switch loginItemState {
        case .enabled: return "已开启"
        case .notRegistered: return "未开启"
        case .requiresApproval: return "需要系统确认"
        case .notFound: return "暂时不可用"
        }
    }
    var loginItemStateMessage: String {
        switch loginItemState {
        case .enabled:
            return "登录这台 Mac 后，句译会自动出现在 Dock 和菜单栏。"
        case .notRegistered:
            return "开启后，句译会在你登录这台 Mac 时自动运行。"
        case .requiresApproval:
            return "macOS 正在等待你的确认。请在系统登录项中允许句译。"
        case .notFound:
            return "macOS 暂时无法注册句译。请确认句译位于“应用程序”文件夹。"
        }
    }

    var statusTitle: String {
        if !hasChecked { return "正在准备句译…" }
        if userPaused { return "句译已暂停" }
        if legacyComponentsPresent { return legacyTitle }
        let native = NativeProductionTranslationCoordinator.shared
        if native.isPreparingLanguages { return "正在准备语言包…" }
        switch native.phase {
        case .active: return "句译已就绪"
        case .requestingAccessibility: return "请允许辅助功能"
        case .legacyComponentsDetected: return legacyTitle
        case .languagePackRequired: return "还需准备语言包"
        case .unsupported: return "此设备暂不支持离线翻译"
        case .disabled: return "启用后即可翻译"
        case .unavailable: return native.cloudCredentialRequired ? "请先配置火山密钥" : "快捷键需要处理"
        }
    }
    var statusMessage: String {
        if !hasChecked { return "这通常只需要几秒。" }
        if userPaused { return "恢复后即可继续使用双击 Option 翻译。" }
        if legacyComponentsPresent { return legacyMessage }
        let native = NativeProductionTranslationCoordinator.shared
        if native.isEnabled { return "选中英文，连按两次 Option，查看中文译文。" }
        return native.detail
    }

    // MARK: Early components (fail-closed)

    var legacyComponentsPresent: Bool { legacyState != .clean }
    var legacyTitle: String {
        switch legacyState {
        case .clean: return ""
        case .removable: return "检测到早期组件"
        case .manual: return "早期组件需要手动处理"
        case .hammerspoonRestartRequired: return "请重新启动 Hammerspoon"
        }
    }
    var legacyMessage: String {
        switch legacyState {
        case .clean:
            return ""
        case .removable:
            return "这台 Mac 上有早期版本留下的快捷键模块、后台服务或配置文件。移除后才能启用双 Option，避免同一次按键被翻译两次；你的其他 Hammerspoon 配置不会改动。"
        case let .manual(paths):
            return "以下项目不是句译创建的，句译不会改动。请手动移走后点击“重新检查”：\n" + paths.joined(separator: "\n")
        case .hammerspoonRestartRequired:
            return "早期快捷键模块已移除，但 Hammerspoon 仍在运行旧配置。重新启动 Hammerspoon 后即可启用双 Option。"
        }
    }
    var legacyActionTitle: String {
        if legacyCleanupBusy { return "正在移除早期组件…" }
        switch legacyState {
        case .clean, .manual: return "重新检查"
        case .removable: return "移除早期组件"
        case .hammerspoonRestartRequired: return "重新启动 Hammerspoon"
        }
    }

    /// Cheap (a few lstat calls, one small file read, one running-app
    /// lookup); runs at launch, before every explicit enable and on refresh.
    func refreshLegacyComponents() {
        let defaults = UserDefaults.standard
        let cleanedAt = defaults.object(forKey: legacyCleanupDateDefaultsKey) as? Date
        let restartPending = LegacyComponentCleanup.hammerspoonRestartPending(
            cleanedAt: cleanedAt,
            runningLaunchDates: cleanedAt == nil ? [] : LegacyComponentCleanup.runningModuleHostLaunchDates()
        )
        if cleanedAt != nil && !restartPending {
            defaults.removeObject(forKey: legacyCleanupDateDefaultsKey)
        }
        let state = LegacyComponentCleanup.state(
            of: LegacyComponentCleanup.inventory(home: home),
            hammerspoonRestartPending: restartPending
        )
        if legacyState != state { legacyState = state }
        NativeProductionTranslationCoordinator.shared.setLegacyComponentsDetected(state != .clean)
    }

    func performLegacyComponentAction() {
        switch legacyState {
        case .clean:
            return
        case .manual:
            refreshLegacyComponents()
            onChange?()
        case .removable, .hammerspoonRestartRequired:
            removeLegacyComponents()
        }
    }

    /// One explicit action removes every owned component: the service
    /// LaunchAgent is booted out and deleted, the module symlink and managed
    /// block are removed, `~/.config/argos-translator` is emptied, and a
    /// running module host is restarted so it drops the module. A plaintext
    /// legacy key is moved into Keychain first; if that fails, nothing is
    /// removed.
    private func removeLegacyComponents() {
        guard !legacyCleanupBusy, !cloudBusy else { return }
        legacyCleanupBusy = true
        cloudBusy = true
        notice = ""
        onChange?()
        Task {
            defer {
                legacyCleanupBusy = false
                cloudBusy = false
                refreshLegacyComponents()
                onChange?()
            }
            let inventory = LegacyComponentCleanup.inventory(home: home)
            if let legacy = inventory.cloudCredentials {
                let migrated = await Task.detached {
                    AppModel.migrateLegacyCloudCredentials(legacy)
                }.value
                guard migrated else {
                    notice = "无法确认钥匙串中的火山密钥，早期组件未移除。请解锁钥匙串后重试。"
                    announce(notice)
                    return
                }
                localCloudCredentialFingerprint = credentialFingerprint(
                    await readCloudCredentialsOffMainActor()
                )
                NativeProductionTranslationCoordinator.shared.cloudCredentialsDidChange()
            }
            let report = await Task.detached {
                LegacyComponentCleanup.perform(
                    inventory,
                    effects: LegacyComponentCleanup.liveEffects { label in
                        _ = AppModel.launchctl(["bootout", "gui/\(getuid())/\(label)"])
                    }
                )
            }.value
            if inventory.moduleHostMayRunIt {
                UserDefaults.standard.set(Date(), forKey: legacyCleanupDateDefaultsKey)
            }
            var restarted = true
            let cleanedAt = UserDefaults.standard.object(forKey: legacyCleanupDateDefaultsKey) as? Date
            if LegacyComponentCleanup.hammerspoonRestartPending(
                cleanedAt: cleanedAt,
                runningLaunchDates: LegacyComponentCleanup.runningModuleHostLaunchDates()
            ) {
                restarted = await LegacyComponentCleanup.restartModuleHost()
            }
            if !report.failed.isEmpty {
                notice = "部分早期组件未能移除：" + report.failed.joined(separator: "、")
            } else if !restarted {
                notice = "早期组件已移除，但无法自动重新启动 Hammerspoon。请手动退出并重新打开 Hammerspoon。"
            } else if let malformed = inventory.malformedInitFile {
                notice = "早期组件已移除。\(malformed) 中的早期配置块格式异常，已原样保留，请手动检查。"
            } else {
                notice = "早期组件已移除。"
            }
            announce(notice)
        }
    }

    // Presentation only: reuse the existing pause and readiness state.
    var translationSetupInProgress: Bool {
        let native = NativeProductionTranslationCoordinator.shared
        return !hasChecked || legacyCleanupBusy || native.isPreparingLanguages
            || native.phase == .requestingAccessibility
    }
    var canPauseTranslation: Bool {
        !userPaused && (NativeProductionTranslationCoordinator.shared.isEnabled
            || translationSetupInProgress)
    }
    var summaryStatus: String {
        if userPaused { return "已暂停" }
        if translationSetupInProgress { return "设置中" }
        if ready { return "已就绪" }
        if !legacyComponentsPresent,
           NativeProductionTranslationCoordinator.shared.phase == .disabled {
            return "未启用"
        }
        return "需要处理"
    }
    var summarySymbol: String {
        if userPaused { return "pause.circle.fill" }
        if translationSetupInProgress { return "clock" }
        if ready { return "checkmark.circle.fill" }
        return summaryStatus == "未启用" ? "circle" : "exclamationmark.circle.fill"
    }
    var summaryColor: Color {
        if userPaused || summaryStatus == "未启用" { return .secondary }
        if translationSetupInProgress { return .accentColor }
        return ready ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange)
    }
    var primaryActionTitle: String {
        let native = NativeProductionTranslationCoordinator.shared
        if userPaused { return "恢复翻译" }
        if ready { return "暂停翻译" }
        if !hasChecked { return "正在检查…" }
        if legacyComponentsPresent { return legacyActionTitle }
        if native.isPreparingLanguages { return "正在准备语言包…" }
        if native.phase == .requestingAccessibility { return "打开系统设置" }
        if native.phase == .languagePackRequired { return "准备语言包" }
        if native.phase == .unsupported { return "诊断与帮助" }
        if native.cloudCredentialRequired { return cloudBusy ? "正在检查云端…" : "设置火山云端" }
        if native.phase == .unavailable { return "重新检查并启用" }
        return onboardingCompleted ? "启用双 Option" : "继续设置"
    }
    var primaryActionEnabled: Bool {
        if userPaused || ready { return true }
        let native = NativeProductionTranslationCoordinator.shared
        if !hasChecked || native.isPreparingLanguages { return false }
        if legacyComponentsPresent { return !legacyCleanupBusy && !cloudBusy }
        if native.cloudCredentialRequired { return !cloudBusy }
        return native.phase == .requestingAccessibility || native.actionIsEnabled
    }
    func performPrimaryAction() {
        guard primaryActionEnabled else { return }
        let native = NativeProductionTranslationCoordinator.shared
        if userPaused || ready { togglePause(); return }
        if legacyComponentsPresent { performLegacyComponentAction() }
        else if native.phase == .requestingAccessibility { openAccessibility() }
        else if native.phase == .languagePackRequired { native.prepareLanguages() }
        else if native.phase == .unsupported { showDiagnostics = true }
        else if native.cloudCredentialRequired { openCloudSettings() }
        else if native.phase == .unavailable || onboardingCompleted { enableNativeShortcut() }
        else { startOnboarding() }
    }

    private func migrateOnboardingState() {
        let defaults = UserDefaults.standard
        let version = defaults.object(forKey: "onboardingVersion") == nil ? nil : defaults.integer(forKey: "onboardingVersion")
        onboardingDisposition = OnboardingPolicy.migratedDisposition(
            storedRawValue: defaults.string(forKey: "onboardingDisposition"),
            storedVersion: version,
            legacyConfirmed: defaults.bool(forKey: "onboardingConfirmed")
        )
        defaults.removeObject(forKey: "onboardingConfirmed")
    }

    func startOnboarding() {
        onboardingPreservesCompletion = OnboardingPolicy.preservesCompletionDuringRerun(onboardingDisposition)
        onboardingDisposition = OnboardingPolicy.dispositionWhenStarting(
            current: onboardingDisposition,
            preservesCompletion: onboardingPreservesCompletion
        )
        permissionTroubleshooting = false
        practiceTroubleshooting = false
        onboardingScreen = firstIncompleteScreen()
        onboardingPresented = true
        onChange?()
    }

    func startInitialOnboarding() {
        onboardingDisposition = OnboardingPolicy.dispositionWhenStarting(
            current: onboardingDisposition,
            preservesCompletion: onboardingPreservesCompletion
        )
        onboardingScreen = .permission
        onboardingPresented = true
        onChange?()
    }

    func relearnShortcut() {
        onboardingPreservesCompletion = OnboardingPolicy.preservesCompletionDuringRerun(onboardingDisposition)
        permissionTroubleshooting = false
        practiceTroubleshooting = false
        onboardingScreen = .practice
        onboardingPresented = true
        onChange?()
    }

    func rerunFullOnboarding() {
        onboardingPreservesCompletion = OnboardingPolicy.preservesCompletionDuringRerun(onboardingDisposition)
        permissionTroubleshooting = false
        practiceTroubleshooting = false
        onboardingScreen = .welcome
        onboardingPresented = true
        showDiagnostics = false
        onChange?()
    }

    func deferOnboarding() {
        onboardingDisposition = OnboardingPolicy.dispositionWhenDeferred(
            current: onboardingDisposition,
            preservesCompletion: onboardingPreservesCompletion
        )
        onboardingPresented = false
        onChange?()
    }

    func advanceOnboarding() {
        switch onboardingScreen {
        case .welcome: startInitialOnboarding()
        case .permission:
            guard NativeProductionTranslationCoordinator.shared.isEnabled else { return }
            onboardingScreen = .practice
        case .practice: confirmHotkeyWorked()
        case .complete: finishOnboarding()
        }
    }

    func finishOnboarding() {
        onboardingPresented = false
        onboardingPreservesCompletion = false
        onChange?()
    }

    private func firstIncompleteScreen() -> OnboardingScreen {
        NativeProductionTranslationCoordinator.shared.isEnabled ? .practice : .permission
    }

    func showPermissionStep() {
        onboardingScreen = .permission
        onChange?()
    }

    func repairShortcut() {
        onboardingPreservesCompletion = onboardingCompleted
        permissionTroubleshooting = false
        practiceTroubleshooting = false
        onboardingScreen = .permission
        onboardingPresented = true
        enableNativeShortcut()
        onChange?()
    }

    func enableNativeShortcut() {
        notice = ""
        let native = NativeProductionTranslationCoordinator.shared
        guard bundleIsInApplicationsFolder else {
            notice = "请先把句译拖到“应用程序”文件夹，再启用双 Option。"
            return
        }
        // Enabling never changes the engine: both engines use this chain.
        if native.isEnabled {
            native.enableByUser()
            return
        }
        // Detect again right before an explicit enable (fail-closed).
        refreshLegacyComponents()
        guard !legacyComponentsPresent else { return }
        native.enableByUser()
    }

    func applicationBecameActive() {
        applicationActive = true
        scheduleRefreshTimer()
        // SMAppService.status is only shown in Diagnostics. The fallback
        // migration runs once per process on the first activation.
        if showDiagnostics { refreshLoginItemState() }
        if !activationLoginItemMigrationChecked {
            activationLoginItemMigrationChecked = true
            migrateFallbackToServiceManagementIfNeeded()
        }
        Task {
            await refresh()
            try? await Task.sleep(for: .milliseconds(700))
            await refresh()
        }
    }

    func refreshLoginItemState() {
        let status = SMAppService.mainApp.status
        let fallbackValid = Self.fallbackLoginItemIsValid(at: fallbackLoginItemPlist)
        if status == .notFound {
            loginItemBackend = .launchAgent
            guard Self.fallbackLoginItemCanBeInstalled(from: Bundle.main.bundleURL) else {
                loginItemState = .notFound
                return
            }
            loginItemState = fallbackValid ? .enabled : .notRegistered
            return
        }
        if fallbackValid && status != .enabled {
            // A future properly signed build migrates this working fallback
            // before presenting ServiceManagement as the active backend.
            loginItemBackend = .launchAgent
            loginItemState = .enabled
            return
        }

        loginItemBackend = .serviceManagement
        switch status {
        case .enabled:
            loginItemState = .enabled
        case .notRegistered:
            loginItemState = .notRegistered
        case .requiresApproval:
            loginItemState = .requiresApproval
        case .notFound:
            loginItemState = .notFound
        @unknown default:
            loginItemState = .notFound
        }
    }

    private func configureDefaultLoginItemIfNeeded() {
        refreshLoginItemState()
        let defaults = UserDefaults.standard

        if SMAppService.mainApp.status != .notFound,
           Self.fallbackLoginItemIsValid(at: fallbackLoginItemPlist) {
            migrateFallbackToServiceManagementIfNeeded()
            return
        }
        guard !defaults.bool(forKey: loginItemRegistrationKey) else { return }

        if loginItemBackend == .launchAgent {
            guard loginItemState != .notFound else {
                loginItemNotice = "自动启动暂时无法设置，请确认句译位于“应用程序”文件夹。"
                return
            }
            defaults.set(true, forKey: loginItemRegistrationKey)
            updateFallbackLoginItem(enabled: true, initialAttempt: true)
            return
        }

        switch loginItemState {
        case .enabled:
            defaults.set(true, forKey: loginItemRegistrationKey)
            return
        case .requiresApproval:
            defaults.set(true, forKey: loginItemRegistrationKey)
            loginItemNotice = "请在系统登录项中允许句译；这不会影响现在使用翻译。"
            return
        case .notFound:
            // Do not consume the one-time attempt when a developer has opened
            // an uninstalled build; a later launch from /Applications retries.
            loginItemNotice = "自动启动暂时无法设置，请确认句译位于“应用程序”文件夹。"
            return
        case .notRegistered:
            break
        }

        // Remember the first real attempt before talking to ServiceManagement
        // so a user's later choice to disable it is never overwritten.
        defaults.set(true, forKey: loginItemRegistrationKey)
        do {
            try SMAppService.mainApp.register()
            refreshLoginItemState()
            if loginItemState == .requiresApproval {
                loginItemNotice = "请在系统登录项中允许句译；这不会影响现在使用翻译。"
            }
        } catch {
            refreshLoginItemState()
            loginItemNotice = loginItemState == .notFound
                ? "自动启动暂时无法设置，请确认句译位于“应用程序”文件夹。"
                : "自动启动暂时没有设置成功，你仍然可以正常使用句译。"
        }
    }

    func setLoginItemEnabled(_ enabled: Bool) {
        guard !loginItemBusy else { return }
        if loginItemBackend == .launchAgent {
            if !enabled, SMAppService.mainApp.status == .requiresApproval {
                try? SMAppService.mainApp.unregister()
            }
            updateFallbackLoginItem(enabled: enabled)
            return
        }
        loginItemBusy = true
        loginItemNotice = ""
        defer {
            loginItemBusy = false
            onChange?()
        }

        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status == .requiresApproval {
                    refreshLoginItemState()
                    loginItemNotice = "请在系统登录项中允许句译；这不会影响现在使用翻译。"
                    return
                }
                if service.status != .enabled { try service.register() }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            refreshLoginItemState()
            if enabled && loginItemState == .requiresApproval {
                loginItemNotice = "请在系统登录项中允许句译；这不会影响现在使用翻译。"
            } else if loginItemEnabled != enabled {
                loginItemNotice = "自动启动暂时没有更改，你仍然可以正常使用句译。"
            }
        } catch {
            refreshLoginItemState()
            loginItemNotice = loginItemState == .notFound
                ? "自动启动暂时无法设置，请确认句译位于“应用程序”文件夹。"
                : "自动启动暂时没有更改，你仍然可以正常使用句译。"
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func updateFallbackLoginItem(enabled: Bool, initialAttempt: Bool = false) {
        guard !loginItemBusy else { return }
        loginItemBusy = true
        loginItemNotice = ""
        let plistURL = fallbackLoginItemPlist
        let bundleURL = Bundle.main.bundleURL
        let launchedByFallback = ProcessInfo.processInfo.arguments.contains("--login-item")
        Task {
            let succeeded = await Task.detached {
                Self.setFallbackLoginItem(
                    enabled: enabled,
                    plistURL: plistURL,
                    currentBundleURL: bundleURL,
                    launchedByFallback: launchedByFallback
                )
            }.value
            refreshLoginItemState()
            loginItemBusy = false
            if !succeeded {
                loginItemNotice = initialAttempt
                    ? "自动启动暂时没有设置成功，你仍然可以正常使用句译。"
                    : "自动启动暂时没有更改，你仍然可以正常使用句译。"
            }
            onChange?()
        }
    }

    private func migrateFallbackToServiceManagementIfNeeded() {
        let status = SMAppService.mainApp.status
        guard !loginItemMigrationInProgress,
              Self.fallbackLoginItemIsValid(at: fallbackLoginItemPlist),
              status == .notRegistered || status == .enabled else { return }
        loginItemMigrationInProgress = true
        loginItemBusy = true
        let plistURL = fallbackLoginItemPlist
        let bundleURL = Bundle.main.bundleURL
        let launchedByFallback = ProcessInfo.processInfo.arguments.contains("--login-item")

        Task {
            if SMAppService.mainApp.status == .notRegistered {
                try? SMAppService.mainApp.register()
            }

            if SMAppService.mainApp.status == .enabled {
                let removed = await Task.detached {
                    Self.setFallbackLoginItem(
                        enabled: false,
                        plistURL: plistURL,
                        currentBundleURL: bundleURL,
                        launchedByFallback: launchedByFallback
                    )
                }.value
                if !removed {
                    // Never leave two enabled login paths. If cleanup fails,
                    // retain the known-working fallback and undo SM adoption.
                    try? await SMAppService.mainApp.unregister()
                }
            }

            refreshLoginItemState()
            loginItemBusy = false
            loginItemMigrationInProgress = false
            onChange?()
        }
    }

    nonisolated private static func fallbackLoginItemCanBeInstalled(from bundleURL: URL) -> Bool {
        let expectedBundle = URL(fileURLWithPath: "/Applications/句译.app", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let currentBundle = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        return currentBundle == expectedBundle
            && FileManager.default.isExecutableFile(atPath: fallbackLoginItemExecutable)
    }

    nonisolated private static func fallbackLoginItemIsValid(at plistURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: plistURL),
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = value as? [String: Any],
              plist["Label"] as? String == fallbackLoginItemLabel,
              plist["ProgramArguments"] as? [String] == [fallbackLoginItemExecutable, "--login-item"],
              plist["RunAtLoad"] as? Bool == true,
              plist["KeepAlive"] as? Bool == false else { return false }
        return true
    }

    nonisolated private static func setFallbackLoginItem(
        enabled: Bool,
        plistURL: URL,
        currentBundleURL: URL,
        launchedByFallback: Bool
    ) -> Bool {
        let fileManager = FileManager.default
        let domain = "gui/\(getuid())"
        let target = "\(domain)/\(fallbackLoginItemLabel)"

        if !enabled {
            do {
                if fileManager.fileExists(atPath: plistURL.path) {
                    try fileManager.removeItem(at: plistURL)
                }
                guard !fileManager.fileExists(atPath: plistURL.path) else { return false }
                // bootout would terminate this process when launchd started it.
                // Removing the plist is sufficient to respect the next login.
                if !launchedByFallback { _ = launchctl(["bootout", target]) }
                return true
            } catch {
                return false
            }
        }

        guard fallbackLoginItemCanBeInstalled(from: currentBundleURL) else { return false }

        let payload: [String: Any] = [
            "Label": fallbackLoginItemLabel,
            "ProgramArguments": [fallbackLoginItemExecutable, "--login-item"],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        let directory = plistURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(fallbackLoginItemLabel).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
            try data.write(to: temporary, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temporary.path)
            guard fallbackLoginItemIsValid(at: temporary) else { return false }

            if fileManager.fileExists(atPath: plistURL.path) {
                _ = try fileManager.replaceItemAt(plistURL, withItemAt: temporary, backupItemName: nil, options: .usingNewMetadataOnly)
            } else {
                try fileManager.moveItem(at: temporary, to: plistURL)
            }
            guard fallbackLoginItemIsValid(at: plistURL) else { return false }

            if launchctl(["print", target]).0 == 0 { return true }
            let bootstrap = launchctl(["bootstrap", domain, plistURL.path])
            if bootstrap.0 == 0 { return true }
            _ = launchctl(["bootout", target])
            try? fileManager.removeItem(at: plistURL)
            return false
        } catch {
            return false
        }
    }

    private static func validEngine(_ value: String?) -> String? {
        guard let value, ["apple", "volc"].contains(value) else { return nil }
        return value
    }

    var engineChoice: NativeTranslationEngineChoice {
        NativeTranslationEngineChoice(rawValue: selectedEngine) ?? .apple
    }

    /// `security` runs as a bounded child process; never wait for it on the
    /// main actor.
    private func readCloudCredentialsOffMainActor() async -> CloudCredentials? {
        let keychainState = await Task.detached {
            AppModel.readKeychainCloudCredentials()
        }.value
        switch keychainState {
        case .found(let credentials): return credentials
        case .notFound, .invalid, .unavailable: return nil
        }
    }

    private func credentialFingerprint(_ credentials: CloudCredentials?) -> String? {
        guard let credentials else { return nil }
        var data = Data(credentials.accessKey.utf8)
        data.append(0)
        data.append(contentsOf: credentials.secretKey.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The periodic tick only re-runs the cheap early-component detection;
    /// neither engine depends on any external process.
    func refresh() async {
        refreshLegacyComponents()
        if !hasChecked { hasChecked = true }
        scheduleRefreshTimer()
        onChange?()
    }

    nonisolated private static func runBoundedProcess(
        executablePath: String,
        arguments: [String],
        input: Data? = nil,
        captureOutput: Bool = false,
        mergeStandardError: Bool = false,
        timeout: DispatchTimeInterval
    ) -> (status: Int32, output: Data) {
        // All current stdin payloads are small Keychain JSON values. Preloading
        // a bounded pipe before launch avoids a writer that could outlive a
        // timed-out child while keeping the secret out of argv and disk.
        guard (input?.count ?? 0) <= 4_096 else { return (1, Data()) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        var inputPipe: Pipe?
        if let input {
            let pipe = Pipe()
            do {
                try pipe.fileHandleForWriting.write(contentsOf: input)
                try pipe.fileHandleForWriting.close()
            } catch {
                pipe.fileHandleForWriting.closeFile()
                pipe.fileHandleForReading.closeFile()
                return (1, Data())
            }
            inputPipe = pipe
            process.standardInput = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let outputPipe = captureOutput ? Pipe() : nil
        let outputBuffer = BoundedProcessOutput()
        let outputFinished = DispatchSemaphore(value: 0)
        if let outputPipe {
            process.standardOutput = outputPipe
            process.standardError = mergeStandardError
                ? outputPipe
                : FileHandle.nullDevice
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    outputFinished.signal()
                } else {
                    outputBuffer.append(data)
                }
            }
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        let processFinished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in processFinished.signal() }
        defer {
            outputPipe?.fileHandleForReading.readabilityHandler = nil
            outputPipe?.fileHandleForReading.closeFile()
            inputPipe?.fileHandleForReading.closeFile()
        }

        do {
            try process.run()
        } catch {
            return (1, Data(error.localizedDescription.utf8))
        }

        let completed = processFinished.wait(timeout: .now() + timeout) == .success
        if !completed {
            process.terminate()
            if processFinished.wait(timeout: .now() + .milliseconds(500)) == .timedOut {
                let pid = process.processIdentifier
                if pid > 1 { _ = Darwin.kill(pid, SIGKILL) }
                _ = processFinished.wait(timeout: .now() + .milliseconds(500))
            }
        }
        if outputPipe != nil {
            _ = outputFinished.wait(timeout: .now() + .milliseconds(500))
        }
        return (completed ? process.terminationStatus : 124, outputBuffer.snapshot())
    }

    nonisolated private static func launchctl(_ args: [String]) -> (Int32, String) {
        let result = runBoundedProcess(
            executablePath: "/bin/launchctl",
            arguments: args,
            captureOutput: true,
            mergeStandardError: true,
            timeout: .seconds(5)
        )
        return (
            result.status,
            String(data: result.output, encoding: .utf8) ?? ""
        )
    }

    nonisolated private static func runSecurity(_ arguments: [String], input: Data? = nil) -> (Int32, Data) {
        let result = runBoundedProcess(
            executablePath: "/usr/bin/security",
            arguments: arguments,
            input: input,
            captureOutput: true,
            timeout: .seconds(8)
        )
        return (result.status, result.output)
    }

    nonisolated private static func readKeychainCloudCredentials(
        service: String = volcKeychainService,
        account: String = volcKeychainAccount
    ) -> CloudCredentialRead {
        let result = runSecurity([
            "find-generic-password", "-s", service,
            "-a", account, "-w",
        ])
        if result.0 == 44 { return .notFound }
        guard result.0 == 0 else { return .unavailable }
        guard var credentials = try? JSONDecoder().decode(CloudCredentials.self, from: result.1) else { return .invalid }
        credentials = CloudCredentials(
            accessKey: credentials.accessKey.trimmingCharacters(in: .whitespacesAndNewlines),
            secretKey: credentials.secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !credentials.accessKey.isEmpty, !credentials.secretKey.isEmpty else { return .invalid }
        return .found(credentials)
    }

    nonisolated private static func saveKeychainCloudCredentials(
        _ credentials: CloudCredentials,
        service: String = volcKeychainService,
        account: String = volcKeychainAccount
    ) -> Bool {
        guard let payload = try? JSONEncoder().encode(credentials) else { return false }
        let result = runSecurity([
            "add-generic-password", "-U", "-s", service,
            "-a", account, "-w",
        ], input: payload)
        return result.0 == 0
    }

    nonisolated private static func deleteKeychainCloudCredentials(
        service: String = volcKeychainService,
        account: String = volcKeychainAccount
    ) -> Bool {
        let result = runSecurity([
            "delete-generic-password", "-s", service,
            "-a", account,
        ])
        guard result.0 == 0 || result.0 == 44 else { return false }
        return readKeychainCloudCredentials(service: service, account: account) == .notFound
    }

    /// The native cloud engine's credential source. Keychain only; runs off
    /// the main actor.
    nonisolated static func readVolcEngineCredentials() -> VolcV4Credentials? {
        guard case .found(let credentials) = readKeychainCloudCredentials() else { return nil }
        return VolcV4Credentials(accessKey: credentials.accessKey, secretKey: credentials.secretKey)
    }

    /// One-time move of a plaintext pre-native `volc.env` key pair into
    /// Keychain, run only by the explicit early-component removal. An existing
    /// Keychain item wins; an unreadable item is never overwritten.
    nonisolated private static func migrateLegacyCloudCredentials(_ legacy: LegacyCloudCredentials) -> Bool {
        switch readKeychainCloudCredentials() {
        case .found:
            return true
        case .notFound:
            let candidate = CloudCredentials(accessKey: legacy.accessKey, secretKey: legacy.secretKey)
            return saveKeychainCloudCredentials(candidate)
                && readKeychainCloudCredentials() == .found(candidate)
        case .invalid, .unavailable:
            return false
        }
    }

    func chooseApple() {
        guard !cloudBusy else { notice = "云端设置正在安全处理，请稍候。"; return }
        setEngine("apple")
        notice = NativeProductionTranslationCoordinator.shared.isEnabled
            ? "已切换到 Apple 离线翻译。"
            : "已选择 Apple 离线。启用双 Option 后即可翻译。"
    }

    func repairCurrentTranslation() {
        let native = NativeProductionTranslationCoordinator.shared
        if native.cloudCredentialRequired {
            openCloudSettings()
        } else if native.phase == .languagePackRequired {
            native.prepareLanguages()
        } else if native.isEnabled {
            native.retryByUser()
        } else {
            enableNativeShortcut()
        }
    }

    func openCloudSettings() {
        cloudError = ""
        showCloudSetup = true
    }

    /// Cloud translation needs only a verified Keychain credential; there is
    /// no background service to start.
    func chooseCloud() {
        guard !cloudBusy else { notice = "云端设置正在安全处理，请稍候。"; return }
        if cloudConfigExists && cloudVerified {
            setEngine("volc")
            notice = "已切换到火山云端翻译。"
        }
        else if cloudConfigExists { validateExistingCloud() }
        else { openCloudSettings() }
    }

    /// UserDefaults is the only engine source; the native chain keeps running.
    private func setEngine(_ engine: String) {
        guard let choice = NativeTranslationEngineChoice(rawValue: engine) else { return }
        UserDefaults.standard.set(choice.rawValue, forKey: selectedEngineDefaultsKey)
        selectedEngine = choice.rawValue
        if choice == .apple { VolcTranslationEngine.shared.forgetCredentials() }
        NativeProductionTranslationCoordinator.shared.setEngine(choice)
        onChange?()
    }

    /// Re-validates the stored credential with one fixed English sentence.
    func validateExistingCloud() {
        guard !testing, !cloudBusy else { return }
        testing = true
        cloudBusy = true
        notice = "正在验证云端连接…"
        Task {
            defer {
                testing = false
                cloudBusy = false
            }
            guard let credentials = await readCloudCredentialsOffMainActor() else {
                notice = "云端设置不完整，请重新配置。"
                openCloudSettings()
                return
            }
            let outcome = await VolcTranslationEngine.shared.validate(
                credentials: VolcV4Credentials(
                    accessKey: credentials.accessKey,
                    secretKey: credentials.secretKey
                )
            )
            guard credentialFingerprint(await readCloudCredentialsOffMainActor()) == credentialFingerprint(credentials) else {
                cloudVerified = false
                notice = "验证期间云端配置已变化，请重新运行验证。"
                announce(notice)
                return
            }
            if case .translated = outcome {
                localCloudCredentialFingerprint = credentialFingerprint(credentials)
                cloudVerified = true
                setEngine("volc")
                notice = "云端连接验证成功，已切换到火山云端。"
            } else {
                cloudVerified = false
                notice = Self.cloudFailureMessage(outcome)
            }
            announce(notice)
        }
    }

    /// The candidate is validated in memory first. Keychain is written only
    /// after a real translation succeeded, so a failed candidate can never
    /// replace the existing credential.
    func configureCloud(accessKey: String, secretKey: String) {
        guard !cloudBusy else { return }
        let access = accessKey.trimmingCharacters(in: .whitespacesAndNewlines), secret = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !access.isEmpty, !secret.isEmpty, !access.contains("\n"), !secret.contains("\n") else { cloudError = "请完整填写两项访问密钥。"; return }
        cloudBusy = true; cloudError = ""
        let candidate = CloudCredentials(accessKey: access, secretKey: secret)
        Task {
            let outcome = await VolcTranslationEngine.shared.validate(
                credentials: VolcV4Credentials(accessKey: access, secretKey: secret)
            )
            guard case .translated = outcome else {
                cloudBusy = false
                cloudError = Self.cloudFailureMessage(outcome) + "原有配置未更改。"
                announce(cloudError)
                return
            }
            let saved = await Task.detached {
                AppModel.saveKeychainCloudCredentials(candidate)
                    && AppModel.readKeychainCloudCredentials() == .found(candidate)
            }.value
            guard saved else {
                cloudBusy = false
                cloudError = "连接验证成功，但无法写入 macOS 钥匙串。请解锁钥匙串后重试。"
                announce(cloudError)
                return
            }
            localCloudCredentialFingerprint = credentialFingerprint(candidate)
            cloudVerified = true
            NativeProductionTranslationCoordinator.shared.cloudCredentialsDidChange()
            setEngine("volc")
            cloudBusy = false
            showCloudSetup = false
            notice = "火山云端已可用。"
            announce(notice)
        }
    }

    /// The UI confirms first. The credential is deleted from Keychain and the
    /// engine returns to Apple either way, so no further selection is sent.
    func removeCloud() {
        guard !cloudBusy else { return }
        cloudBusy = true
        cloudError = ""
        Task {
            let deleted = await Task.detached {
                AppModel.deleteKeychainCloudCredentials()
            }.value
            setEngine("apple")
            NativeProductionTranslationCoordinator.shared.cloudCredentialsDidChange()
            localCloudCredentialFingerprint = credentialFingerprint(
                await readCloudCredentialsOffMainActor()
            )
            cloudVerified = false
            cloudBusy = false
            if deleted {
                showCloudSetup = false
                notice = "已移除火山云端设置，当前只使用离线翻译。"
                announce(notice)
            } else {
                cloudError = "已切换到 Apple 离线，但暂时无法从钥匙串删除火山密钥。请解锁钥匙串后重试。"
                announce(cloudError)
            }
        }
    }

    func testTranslation() {
        guard !testing, !cloudBusy else { return }; testing = true; testResult = ""; testDetail = "正在测试翻译…"
        let engine = selectedEngine
        Task {
            if engine == "apple" {
                let result = await NativeAppleProductionTranslationService.shared
                    .translate(VolcTranslationEngine.validationText)
                testing = false
                switch result {
                case let .translated(text):
                    testResult = text
                    testDetail = "Apple 离线 · 本机翻译成功；请在文本编辑中实际试用双 Option。"
                case .needsPreparation:
                    testDetail = "需要准备中英语言包，请点击“准备 Apple 语言包”。"
                case .unsupported:
                    testDetail = "此设备暂不支持英语到中文的 Apple 翻译。"
                case .cancelled:
                    testDetail = "测试已取消，可以重新尝试。"
                default:
                    testDetail = "Apple 翻译暂未完成，请重试或检查系统语言包。"
                }
                return
            }
            let started = ProcessInfo.processInfo.systemUptime
            let outcome = await VolcTranslationEngine.shared.validateStoredCredentials()
            let elapsed = Int(max(0, (ProcessInfo.processInfo.systemUptime - started) * 1_000).rounded())
            testing = false
            if case let .translated(text) = outcome {
                testResult = text
                testDetail = "火山云端 · \(elapsed) 毫秒 · 仅确认翻译方式；请在文本编辑中实际试用双 Option。"
                cloudVerified = true
            } else {
                testResult = ""
                testDetail = Self.cloudFailureMessage(outcome)
                announce(testDetail)
            }
        }
    }

    private static func cloudFailureMessage(_ outcome: VolcTranslationOutcome) -> String {
        switch outcome {
        case .translated: return ""
        case .cancelled: return "云端验证已取消，可以重新尝试。"
        case let .failed(error):
            switch error {
            case .credential: return "火山云端拒绝了这组密钥。请确认已经开通机器翻译服务，并检查两项密钥和访问权限。"
            case .network: return "暂时无法连接火山云端，请检查网络后重试。"
            case .timeout: return "火山云端响应超时，请检查网络后重试。"
            case .httpFailure: return "火山云端暂时无法完成翻译，请稍后重试。"
            case .malformedResponse, .emptyResult: return "火山云端没有返回译文，请稍后重试。"
            }
        }
    }

    func openAccessibility() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    func confirmHotkeyWorked() {
        guard NativeProductionTranslationCoordinator.shared.isEnabled else { return }
        onboardingDisposition = .completed
        onboardingPreservesCompletion = true
        onboardingScreen = .complete
        notice = ""
        announce("句译准备好了")
        onChange?()
    }
    func openPracticeDocument() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Juyi-Practice-\(UUID().uuidString).txt")
        do {
            try "Good tools should feel effortless.\n".write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                configuration: .init()
            ) { _, error in
                if error != nil {
                    Task { @MainActor in self.notice = "无法打开文本编辑，请手动新建文稿并输入示例英文。" }
                }
            }
        } catch {
            notice = "无法创建练习文稿，请在文本编辑中新建文稿并输入示例英文。"
        }
    }
    func togglePause() {
        paused.toggle()
        UserDefaults.standard.set(paused, forKey: pausedDefaultsKey)
        NativeProductionTranslationCoordinator.shared.setPaused(paused)
        onChange?()
    }

    /// Quitting stops translation and is remembered: the next launch stays
    /// paused until the user chooses "恢复翻译".
    func pauseForTermination() {
        paused = true
        UserDefaults.standard.set(true, forKey: pausedDefaultsKey)
        NativeProductionTranslationCoordinator.shared.setPaused(true)
    }
    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [.announcement: message])
    }
}

private struct Surface: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(18).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

private enum OnboardingAccessibilityFocus: Hashable {
    case pageTitle, statusSummary
}

private struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var nativeTranslation =
        NativeProductionTranslationCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var accessibilityFocus: OnboardingAccessibilityFocus?
    @State private var showPermissionExplanation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("句译").font(.headline)
                Spacer()
                Text(progressText).font(.callout).foregroundStyle(.secondary).accessibilityLabel(progressAccessibilityLabel)
            }.padding(.horizontal, 28).padding(.vertical, 18)
            Divider()
            ScrollView {
                Group {
                    switch model.onboardingScreen {
                    case .welcome: welcome
                    case .permission: permission
                    case .practice: practice
                    case .complete: complete
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .transition(.opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: model.onboardingScreen)
            }
            .id(model.onboardingScreen)
            Divider()
            onboardingFooter.padding(.horizontal, 34).padding(.vertical, 16)
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focusAndAnnouncePage() }
        .onChange(of: model.onboardingScreen) { focusAndAnnouncePage() }
        .onChange(of: model.legacyState) { announceShortcutStatus() }
        .onChange(of: nativeTranslation.phase) { announceShortcutStatus() }
    }

    private func announceShortcutStatus() {
        guard model.onboardingScreen == .permission else { return }
        let state = shortcutStatus
        announce("快捷键状态：\(state.title)。\(state.detail)")
        DispatchQueue.main.async { accessibilityFocus = .statusSummary }
    }

    @ViewBuilder private var onboardingFooter: some View {
        switch model.onboardingScreen {
        case .welcome:
            footer(primary: "开始设置", primaryEnabled: true) { model.advanceOnboarding() }
        case .permission:
            shortcutFooter
        case .practice:
            HStack {
                Button("稍后再说") { model.deferOnboarding() }.keyboardShortcut(.cancelAction)
                Button("没有出现译文") { model.practiceTroubleshooting.toggle() }
                Spacer()
                if nativeTranslation.isEnabled {
                    Button("我看到了译文") { model.confirmHotkeyWorked() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("返回检查快捷键") { model.showPermissionStep() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        case .complete:
            HStack { Spacer(); Button("开始使用") { model.finishOnboarding() }.keyboardShortcut(.defaultAction) }
        }
    }

    /// Welcome and completion frame the two real steps: prepare, then practice.
    private var progressText: String {
        switch model.onboardingScreen {
        case .welcome: return "准备 · 练习 · 完成"
        case .permission: return "第 1 步 · 准备"
        case .practice: return "第 2 步 · 练习"
        case .complete: return "完成"
        }
    }

    private var progressAccessibilityLabel: String {
        switch model.onboardingScreen {
        case .permission: return "第 1 步，共 2 步：准备快捷键和翻译"
        case .practice: return "第 2 步，共 2 步：实际试用"
        case .welcome, .complete: return ""
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(spacing: 8) {
                Text("选中英文，旁边就是中文").font(.system(size: 25, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($accessibilityFocus, equals: .pageTitle)
                Text("不用切换窗口。默认由 Apple 在这台 Mac 上翻译。")
                    .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 16) {
                welcomeAction("选中英文", symbol: "selection.pin.in.out")
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                HStack(spacing: 4) { keycap("⌥"); keycap("⌥") }
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                welcomeAction("查看中文", symbol: "character.bubble")
            }.accessibilityElement(children: .combine).accessibilityLabel("选中英文，然后连按两次 Option，查看中文")
            Text("先在文本编辑中试用；其他 App 和文字层 PDF 能否取词取决于其选区接口。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 34).padding(.vertical, 24)
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepTitle("完成首次准备", subtitle: model.selectedEngine == "volc"
                ? "允许辅助功能、保存火山密钥，就能启用双 Option。"
                : "允许辅助功能、准备 Apple 语言资源，就能启用双 Option。")
            DisclosureGroup("这项权限有什么作用？", isExpanded: $showPermissionExplanation) {
                Text("macOS 将选区读取和全局按键归入“辅助功能”权限。句译只在你触发翻译时读取选中的文字；你可以随时在系统设置中关闭权限。")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            }
            shortcutStatusCard
            if !model.notice.isEmpty {
                Label(model.notice, systemImage: "info.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !nativeTranslation.isEnabled {
                HStack(spacing: 12) {
                    Button("重新检查") { Task { await model.refresh() } }
                    Button("仍然无法完成…") { model.permissionTroubleshooting.toggle() }.buttonStyle(.link)
                }
            }
            if model.permissionTroubleshooting {
                VStack(alignment: .leading, spacing: 6) {
                    Text("仍然无法完成？").font(.subheadline.weight(.medium))
                    Text(model.legacyComponentsPresent
                        ? "这台 Mac 留有早期版本的组件，请先点击“\(model.legacyActionTitle)”。句译只移除自己创建的项目，不会改动你的其他配置。"
                        : "请在辅助功能中允许句译，返回这里重新检查。语言资源准备由 macOS 完成，不需要额外安装快捷键工具。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("打开诊断") { model.showDiagnostics = true }.buttonStyle(.link)
                }
            }
        }.padding(.horizontal, 34).padding(.vertical, 28)
    }

    private var shortcutStatusCard: some View {
        let state = shortcutStatus
        return VStack(alignment: .leading, spacing: 12) {
            if model.legacyComponentsPresent {
                preparationRow("移除早期版本留下的组件",
                    detail: "仅升级自早期版本的 Mac 需要这一步；移除前不会启用双 Option。",
                    complete: false)
                Divider()
            }
            preparationRow("允许句译使用辅助功能",
                detail: "用于按键监听和读取选区。授权后返回句译，会自动复检。",
                complete: AccessibilityController.status == .authorized)
            Divider()
            if model.selectedEngine == "volc" {
                preparationRow("火山云端访问密钥",
                    detail: model.cloudConfigExists ? "已保存在钥匙串中；选中的英文会发送至火山翻译。" : "在“翻译方式”中打开火山云端设置并保存访问密钥。",
                    complete: model.cloudConfigExists && !nativeTranslation.cloudCredentialRequired)
            } else {
                preparationRow("Apple 英语 → 简体中文语言资源",
                    detail: nativeTranslation.isEnabled ? "已准备好，可在本机翻译。" : "首次准备可能联网，并需要你确认系统下载提示。",
                    complete: nativeTranslation.isEnabled)
            }
            Divider()
            Label(state.title, systemImage: state.symbol).font(.callout.weight(.medium)).foregroundStyle(state.color)
            Text(state.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.modifier(Surface()).accessibilityElement(children: .combine)
            .accessibilityFocused($accessibilityFocus, equals: .statusSummary)
    }

    private func preparationRow(_ title: String, detail: String, complete: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: complete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(complete ? Color(nsColor: .systemGreen) : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title)：\(complete ? "已确认" : "待检查")。\(detail)")
    }
    private typealias ShortcutState = (symbol: String, color: Color, title: String, detail: String)
    private var shortcutStatus: ShortcutState {
        let orange = Color(nsColor: .systemOrange)
        if model.userPaused {
            return ("pause.circle.fill", orange, "句译目前已暂停", "恢复翻译后即可继续设置或练习双击 Option。")
        }
        if nativeTranslation.isEnabled {
            return ("checkmark.circle.fill", Color(nsColor: .systemGreen), "双 Option 已启用", "现在可以到文本编辑中选中英文，试一次翻译。")
        }
        if model.legacyComponentsPresent {
            return ("shippingbox.fill", orange, model.legacyTitle, model.legacyMessage)
        }
        switch nativeTranslation.phase {
        case .requestingAccessibility:
            return ("hand.raised.fill", .secondary, "正在等待辅助功能权限…", nativeTranslation.detail)
        case .legacyComponentsDetected:
            return ("shippingbox.fill", orange, "检测到早期组件", nativeTranslation.detail)
        case .languagePackRequired:
            return ("arrow.down.circle.fill", orange, nativeTranslation.isPreparingLanguages ? "正在准备 Apple 语言包…" : "需要准备 Apple 语言包", nativeTranslation.detail)
        case .unsupported:
            return ("xmark.circle.fill", Color(nsColor: .systemRed), "这台 Mac 不支持 Apple 离线翻译", nativeTranslation.detail)
        case .unavailable where nativeTranslation.cloudCredentialRequired:
            return ("key.fill", orange, "请先配置火山密钥", nativeTranslation.detail)
        case .unavailable:
            return ("exclamationmark.circle.fill", orange, "原生双 Option 尚未启用", nativeTranslation.detail)
        case .active, .disabled:
            return ("hand.tap.fill", orange, "可以启用双 Option", "点击启用后，按系统提示为句译开启辅助功能权限。")
        }
    }

    @ViewBuilder private var shortcutFooter: some View {
        let enable = { model.enableNativeShortcut() }
        if model.userPaused {
            footer(primary: "恢复翻译", primaryEnabled: true) { model.togglePause() }
        } else if nativeTranslation.isEnabled {
            footer(primary: "继续", primaryEnabled: true) { model.advanceOnboarding() }
        } else if model.legacyComponentsPresent {
            footer(primary: model.legacyActionTitle, primaryEnabled: !model.legacyCleanupBusy && !model.cloudBusy) {
                model.performLegacyComponentAction()
            }
        } else {
            switch nativeTranslation.phase {
            case .requestingAccessibility:
                footer(primary: "打开系统设置", primaryEnabled: true) { model.openAccessibility() }
            case .legacyComponentsDetected:
                footer(primary: "重新检查", primaryEnabled: true) { model.performLegacyComponentAction() }
            case .languagePackRequired:
                footer(primary: nativeTranslation.isPreparingLanguages ? "正在准备…" : "准备 Apple 语言包", primaryEnabled: !nativeTranslation.isPreparingLanguages) { nativeTranslation.prepareLanguages() }
            case .unsupported:
                footer(primary: "重新检查 Apple 翻译", primaryEnabled: nativeTranslation.actionIsEnabled, action: enable)
            case .unavailable where AccessibilityController.status != .authorized:
                footer(primary: "打开辅助功能设置", primaryEnabled: true) { model.openAccessibility() }
            case .unavailable where nativeTranslation.cloudCredentialRequired:
                footer(primary: "设置火山云端", primaryEnabled: !model.cloudBusy) { model.openCloudSettings() }
            case .unavailable:
                footer(primary: "重新尝试", primaryEnabled: nativeTranslation.actionIsEnabled, action: enable)
            case .active:
                footer(primary: "继续", primaryEnabled: true) { model.advanceOnboarding() }
            case .disabled:
                footer(primary: "启用双 Option", primaryEnabled: nativeTranslation.actionIsEnabled, action: enable)
            }
        }
    }

    private var practice: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepTitle("在另一个 App 里试一次", subtitle: "打开示例文稿，选中英文，再连按两次 Option。")
            VStack(alignment: .leading, spacing: 14) {
                Label("先在“文本编辑”中试一次", systemImage: "macwindow.on.rectangle")
                    .font(.headline)
                Text("点击下方按钮，在文本编辑中打开这句英文：")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Good tools should feel effortless.")
                    .font(.callout.monospaced()).textSelection(.enabled)
                Button("在文本编辑中打开") { model.openPracticeDocument() }
                HStack { Spacer(); keycap("⌥"); keycap("⌥"); Spacer() }
                Text("译文会出现在选中文字附近。").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
                Text("句译不会读取自身窗口中的文字；这是为了避免把设置页误当成翻译目标。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.modifier(Surface())
            Text("WPS PDF 兼容取词会临时使用剪贴板，剪贴板管理器可能保留原文；扫描图片型 PDF 暂不支持。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !nativeTranslation.isEnabled {
                Label(nativeTranslation.detail, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(Color(nsColor: .systemOrange))
                Button("返回检查快捷键") { model.showPermissionStep() }
            }
            if model.practiceTroubleshooting {
                VStack(alignment: .leading, spacing: 5) {
                    Text("没有出现译文？").font(.subheadline.weight(.medium))
                    Text("先在文本编辑中选中整句英文；两次 Option 都要快速按下并松开。如果文本编辑可用但某个 App 不可用，该 App 可能不提供可读取选区。")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack { Button("检查句译权限") { model.openAccessibility() }; Button("打开诊断") { model.showDiagnostics = true } }
                }
            }
        }.padding(.horizontal, 34).padding(.vertical, 28)
    }

    private var complete: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 58)).foregroundStyle(Color(nsColor: .systemGreen)).accessibilityHidden(true)
            Text("句译准备好了").font(.system(size: 28, weight: .semibold)).accessibilityAddTraits(.isHeader)
                .accessibilityFocused($accessibilityFocus, equals: .pageTitle)
            Text("以后只需：选中英文，连按两次 Option。")
                .font(.title3).multilineTextAlignment(.center)
            Button("后台运行与停止…") { model.showSupportInfo = true }.buttonStyle(.link)
        }.padding(.horizontal, 34).padding(.vertical, 36)
    }

    private func stepTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 25, weight: .semibold)).accessibilityAddTraits(.isHeader)
                .accessibilityFocused($accessibilityFocus, equals: .pageTitle)
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func footer(primary: String, primaryEnabled: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Button(model.translationSetupInProgress ? "暂停并稍后继续" : "稍后再说") {
                if model.translationSetupInProgress && !model.userPaused { model.togglePause() }
                model.deferOnboarding()
            }.keyboardShortcut(.cancelAction)
            Spacer()
            Button(primary, action: action).keyboardShortcut(.defaultAction).disabled(!primaryEnabled)
        }
    }

    private func focusAndAnnouncePage() {
        announce(progressAccessibilityLabel.isEmpty ? pageTitle : "\(progressAccessibilityLabel)。\(pageTitle)")
        DispatchQueue.main.async { accessibilityFocus = .pageTitle }
    }

    private var pageTitle: String {
        switch model.onboardingScreen {
        case .welcome: return "欢迎使用句译"
        case .permission: return "允许句译响应快捷键"
        case .practice: return "试一次，马上就会"
        case .complete: return "句译准备好了"
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [.announcement: message]
        )
    }

    private func welcomeAction(_ title: String, symbol: String) -> some View {
        VStack(spacing: 6) { Image(systemName: symbol).font(.title2); Text(title).font(.callout.weight(.medium)) }
            .frame(width: 96, height: 64).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
    }
    private func keycap(_ text: String) -> some View { Text(text).font(.system(size: 18, weight: .semibold, design: .rounded)).frame(width: 38, height: 34).background(.quaternary, in: RoundedRectangle(cornerRadius: 7)) }
}

private struct CloudSetupView: View {
    @ObservedObject var model: AppModel
    @State private var access = ""
    @State private var secret = ""
    @State private var reveal = false
    @State private var confirmRemoval = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Image(systemName: "cloud.fill").font(.title).foregroundStyle(.blue); VStack(alignment: .leading) { Text("火山翻译配置").font(.title2.bold()); Text("需联网并配置火山密钥；选中的英文会发送至火山").foregroundStyle(.secondary) } }
            Text("句译直接连接火山翻译，无需另装后台组件。请使用火山的访问密钥，不支持其他服务商的密钥。保存前会用一句固定英文验证；密钥只保存在这台 Mac 的钥匙串中。")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) { Text("Access Key ID").font(.subheadline.weight(.medium)); TextField("输入 Access Key ID", text: $access).textFieldStyle(.roundedBorder) }
            VStack(alignment: .leading, spacing: 6) { Text("Secret Access Key").font(.subheadline.weight(.medium)); HStack { Group { if reveal { TextField("输入 Secret Access Key", text: $secret) } else { SecureField("输入 Secret Access Key", text: $secret) } }.textFieldStyle(.roundedBorder); Button(reveal ? "隐藏" : "显示") { reveal.toggle() } } }
            Button("如何获取访问密钥？") { NSWorkspace.shared.open(URL(string: "https://console.volcengine.com/")!) }.buttonStyle(.link)
            if model.cloudConfigExists && !model.cloudBusy {
                HStack { Label("这台 Mac 已保存一组火山密钥。", systemImage: "checkmark.shield"); Spacer(); Button("重新验证") { model.validateExistingCloud() } }
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !model.cloudError.isEmpty { Label(model.cloudError, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red).font(.callout) }
            Spacer()
            HStack { if model.cloudConfigExists { Button("移除已有云端配置…", role: .destructive) { confirmRemoval = true } }; Spacer(); Button("取消") { model.showCloudSetup = false }.keyboardShortcut(.cancelAction).disabled(model.cloudBusy); Button(model.cloudBusy ? "正在验证…" : "保存并验证") { model.configureCloud(accessKey: access, secretKey: secret) }.keyboardShortcut(.defaultAction).disabled(model.cloudBusy) }
        }.padding(28).frame(width: 500, height: 470)
            .interactiveDismissDisabled(model.cloudBusy)
            .alert("移除云端翻译设置？", isPresented: $confirmRemoval) {
                Button("取消", role: .cancel) {}
                Button("移除", role: .destructive) { model.removeCloud() }
            } message: { Text("句译将从钥匙串删除火山密钥并切换到 Apple 离线，选中的文字不再发送到火山翻译。") }
    }
}

private struct DiagnosticsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var nativeTranslation = NativeProductionTranslationCoordinator.shared
    /// Stacked on this sheet: RootView presents only one sheet at a time.
    @State private var showSupportInfo = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("诊断与帮助").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text("先在文本编辑中选中英文并试用双 Option；这里可以检查权限、语言包和兼容范围。").foregroundStyle(.secondary)
                sectionTitle("状态与修复")
                GroupBox("当前状态") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("双 Option：\(model.hotkeyReady ? "已启用" : "尚未启用")", systemImage: model.hotkeyReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        Text("当前引擎：\(model.selectedEngine == "apple" ? "Apple 离线" : "火山云端")")
                        Text(nativeTranslation.detail).foregroundStyle(.secondary)
                        Text(model.selectedEngine == "apple"
                            ? "Apple 翻译直接在本机运行。"
                            : "火山云端由句译直接连接；选中的英文会发送至火山，密钥保存在钥匙串中。")
                            .font(.caption).foregroundStyle(.secondary)
                        Label(model.legacyComponentsPresent ? "早期组件：\(model.legacyTitle)" : "早期组件：未发现", systemImage: "shippingbox")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                HStack {
                    Button("重新检查") { Task { await model.refresh() } }
                    Button("重新启用双 Option") { model.repairCurrentTranslation() }
                        .disabled(model.userPaused || !nativeTranslation.actionIsEnabled)
                    Button("辅助功能设置") { model.openAccessibility() }
                }
                if model.selectedEngine == "apple" {
                    Button(nativeTranslation.isPreparingLanguages ? "正在准备语言包…" : "准备 Apple 语言包") { nativeTranslation.prepareLanguages() }
                        .disabled(model.userPaused || nativeTranslation.isPreparingLanguages)
                } else {
                    Button("检查火山云端设置") { model.openCloudSettings() }
                        .disabled(model.cloudBusy)
                }
                if model.legacyComponentsPresent {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.legacyMessage).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(model.legacyActionTitle) { model.performLegacyComponentAction() }
                            .disabled(model.legacyCleanupBusy || model.cloudBusy)
                    }
                }
                Divider()
                sectionTitle("设置")
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("登录时自动打开句译").font(.headline)
                            Text(model.loginItemStateTitle).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("登录时自动打开句译", isOn: Binding(
                            get: { model.loginItemEnabled },
                            set: { model.setLoginItemEnabled($0) }
                        ))
                        .labelsHidden()
                        .disabled(model.loginItemBusy || model.loginItemState == .notFound)
                    }
                    Text(model.loginItemStateMessage).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.loginItemNotice.isEmpty {
                        Label(model.loginItemNotice, systemImage: "info.circle.fill")
                            .font(.callout).foregroundStyle(Color(nsColor: .systemOrange))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.loginItemState == .requiresApproval || model.loginItemState == .notFound {
                        Button("打开系统登录项设置") { model.openLoginItemsSettings() }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("测试当前翻译方式").font(.headline)
                    Text("这只检查当前翻译引擎，实际划词与双 Option 仍需在其他 App 中试用。").font(.callout).foregroundStyle(.secondary)
                    Button(model.testing ? "正在测试…" : "测试翻译引擎") { model.testTranslation() }
                        .disabled(model.testing || model.cloudBusy || model.paused || (model.selectedEngine == "volc" && !model.cloudConfigExists))
                    if !model.testResult.isEmpty {
                        Text(model.testResult).textSelection(.enabled)
                        Text(model.testDetail).font(.caption).foregroundStyle(.secondary)
                    } else if !model.testDetail.isEmpty {
                        Text(model.testDetail).font(.callout).foregroundStyle(model.testing ? Color.secondary : Color(nsColor: .systemRed))
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Text("重新运行设置").font(.headline)
                    Text("从头复检翻译、权限和实际快捷键，不会清除引擎、密钥或其他设置。").font(.callout).foregroundStyle(.secondary)
                    Button("重新运行完整设置…") { model.rerunFullOnboarding() }
                }
                Divider()
                HStack {
                    Button("支持范围与隐私") { showSupportInfo = true }.buttonStyle(.link)
                    Spacer()
                    Button("完成") { model.showDiagnostics = false }.keyboardShortcut(.defaultAction)
                }
            }.padding(28)
        }.frame(width: 500, height: 500)
            .sheet(isPresented: $showSupportInfo) { SupportInfoView() }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
    }
}

private struct SupportInfoView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("支持范围与隐私").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("哪些文字可以翻译？", symbol: "text.cursor") {
                        Text("当前仅支持英语 → 简体中文。先在文本编辑中试用；网页、其他 App 和含文字层的 PDF 能否读取，取决于具体 App 提供的选区接口。")
                        Text("扫描图片型 PDF、图片中的文字、安全输入框及受保护内容不支持。句译不会读取自身设置窗口中的文字。")
                    }
                    section("本地翻译 · Apple", symbol: "lock.shield") {
                        Text("由 Apple 提供，翻译在本机完成，无需密钥。首次准备英语和简体中文语言资源可能需要联网；准备完成后可离线使用，失败时不会自动改用云端。")
                    }
                    section("WPS PDF 与剪贴板", symbol: "doc.on.clipboard") {
                        Text("WPS PDF 的兼容取词会临时执行系统复制，并尽力恢复原剪贴板。剪贴板管理器可能保留原文或干扰取词；敏感内容请避免使用这条路径。")
                    }
                    section("云端翻译 · 火山", symbol: "cloud") {
                        Text("目前仅支持火山翻译，需联网并配置火山密钥，不支持其他服务商或自定义 API。只有你主动选择并配置云端后，选中的英文才会发送至火山翻译；失败时不会自动改用 Apple。密钥保存在这台 Mac 的钥匙串中。")
                    }
                    section("后台运行与停止", symbol: "menubar.rectangle") {
                        Text("关闭窗口：句译继续运行。\n暂停翻译：停止翻译，保留设置。\n退出句译：停止翻译；重开后需要点击“恢复翻译”。")
                        Text("按键监听、取词和翻译（Apple 离线与火山云端）都由句译独立完成，无需安装其他工具。若检测到早期版本留下的组件，句译会先提示你一键移除，再启用双 Option。")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 472, height: 510)
    }
    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            VStack(alignment: .leading, spacing: 6, content: content)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AppView: View {
    @ObservedObject var model: AppModel
    @State private var showOtherEngines = false
    @ObservedObject private var nativeTranslation = NativeProductionTranslationCoordinator.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable()
                        .frame(width: 40, height: 40).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("句译").font(.headline)
                        Text(model.selectedEngine == "apple"
                            ? "英语 → 简体中文 · 本地翻译（Apple）"
                            : "英语 → 简体中文 · 云端翻译（火山）")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Label(model.summaryStatus, systemImage: model.summarySymbol)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(model.summaryColor)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(model.summaryColor.opacity(0.10), in: Capsule())
                        .accessibilityLabel("翻译状态：\(model.summaryStatus)")
                }
                statusPanel
                settingsList
                if !model.notice.isEmpty {
                    Label(model.notice, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top) {
                    Text("开发者预览 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    Spacer()
                    Text(model.selectedEngine == "apple" ? "原生本地翻译" : "原生云端翻译")
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.top, 40).padding(.bottom, 20)
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.ready {
                HStack(alignment: .top, spacing: 16) {
                    HStack(spacing: 6) { keycap(); keycap() }.accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("选中英文，连按两次 Option").font(.system(size: 17, weight: .semibold))
                        Text("译文出现在选区旁。关闭此窗口后，句译会在菜单栏继续运行。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    if model.translationSetupInProgress { ProgressView().controlSize(.small) }
                    Text(model.userPaused ? "需要时，随时继续" : model.statusTitle)
                        .font(.system(size: 19, weight: .semibold)).accessibilityAddTraits(.isHeader)
                }
                Text(panelDetail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if nativeTranslation.phase == .disabled
                    && !model.userPaused && !model.translationSetupInProgress {
                    Text(model.selectedEngine == "apple"
                        ? "需要句译辅助功能权限和 Apple 中英语言资源；无需另装快捷键工具。"
                        : "需要句译辅助功能权限和火山密钥；无需另装快捷键工具或后台组件。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                if model.ready {
                    Button(model.primaryActionTitle) { model.performPrimaryAction() }
                } else {
                    Button(model.primaryActionTitle) { model.performPrimaryAction() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.primaryActionEnabled)
                }
                Spacer(minLength: 0)
                if !model.ready && model.canPauseTranslation {
                    Button(model.translationSetupInProgress ? "暂停并稍后继续" : "暂停所有翻译") {
                        model.togglePause()
                    }.font(.callout)
                }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var panelDetail: String {
        if model.userPaused {
            return "现在连按两次 Option 不会翻译。设置仍保留；退出后重新打开，也需要手动恢复。"
        }
        if model.ready { return "" }
        if nativeTranslation.phase == .disabled
            && !model.translationSetupInProgress {
            return model.onboardingCompleted ? "启用快捷键后，即可在其他 App 中划词翻译。" : "跟随设置完成授权，再在文本编辑中试一次真实翻译。"
        }
        return model.statusMessage
    }

    private var settingsList: some View {
        VStack(spacing: 0) {
            DisclosureGroup(isExpanded: $showOtherEngines) {
                VStack(alignment: .leading, spacing: 10) {
                    Button("使用本地翻译") { model.chooseApple() }
                    Text("由 Apple 提供，翻译在本机完成，无需密钥。首次准备语言资源可能需要联网，之后可离线使用。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Button("使用云端翻译…") { model.chooseCloud() }
                    Text("目前仅支持火山翻译，需联网并配置火山密钥；选中的英文会发送至火山翻译。不支持其他服务商的密钥或自定义 API。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.cloudConfigExists {
                        Button("管理火山翻译配置…") { model.openCloudSettings() }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            } label: {
                HStack {
                    Text("翻译方式")
                    Spacer()
                    Text(model.selectedEngine == "apple" ? "本地 · Apple" : "云端 · 火山").foregroundStyle(.secondary)
                }
            }.padding(12).disabled(model.cloudBusy || model.translationSetupInProgress)
            Divider().padding(.horizontal, 12)
            settingsRow("支持范围与隐私", symbol: "hand.raised") { model.showSupportInfo = true }
            Divider().padding(.horizontal, 12)
            settingsRow("诊断与帮助", symbol: "questionmark.circle") { model.showDiagnostics = true }
            if model.onboardingCompleted {
                Divider().padding(.horizontal, 12)
                settingsRow("重新练习双 Option", symbol: "keyboard") { model.relearnShortcut() }
            } else if model.ready {
                Divider().padding(.horizontal, 12)
                settingsRow("完成首次练习", symbol: "keyboard") { model.startOnboarding() }
            }
        }.font(.callout)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func settingsRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(12).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func keycap() -> some View {
        Text("⌥").font(.system(size: 22, weight: .medium, design: .rounded))
            .frame(width: 42, height: 44)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

private struct RootView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Group {
            if model.onboardingPresented { OnboardingView(model: model) }
            else { AppView(model: model) }
        }
        .sheet(isPresented: $model.showCloudSetup) { CloudSetupView(model: model) }
        .sheet(isPresented: $model.showDiagnostics) { DiagnosticsView(model: model) }
        .sheet(isPresented: $model.showSupportInfo) { SupportInfoView() }
        .background(
            NativeAppleProductionTranslationHost(
                service: NativeAppleProductionTranslationService.shared
            )
        )
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var window: NSWindow!
    private var lastOnboardingMode: Bool?
    private var chromeGate = AppChromeRenderGate()
    private var nativeProductionIsAwake = true
    private var nativeProductionSessionIsActive = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isLoginLaunch = launchedFromLogin
        NSApp.setActivationPolicy(.regular); installMainMenu(); createWindow()
        model.onChange = { [weak self] in self?.updateChrome() }; updateChrome()
        NativeTranslationOverlayController.shared.configureNavigation {
            [weak self] cta in self?.handleNativeOverlayCTA(cta)
        }
        NativeTranslationOverlayController.shared.setPaused(model.paused)
        // Coordinator changes reach the chrome once, through AppModel.onChange.
        NativeProductionTranslationCoordinator.shared.setPaused(model.paused)
        NativeProductionTranslationCoordinator.shared
            .setEngine(model.engineChoice)
        let nativeWorkspaceCenter = NSWorkspace.shared.notificationCenter
        nativeWorkspaceCenter.addObserver(
            self, selector: #selector(nativeProductionWillSleep(_:)),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        nativeWorkspaceCenter.addObserver(
            self, selector: #selector(nativeProductionDidWake(_:)),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        nativeWorkspaceCenter.addObserver(
            self, selector: #selector(nativeProductionSessionResigned(_:)),
            name: NSWorkspace.sessionDidResignActiveNotification, object: nil
        )
        nativeWorkspaceCenter.addObserver(
            self, selector: #selector(nativeProductionSessionBecameActive(_:)),
            name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil
        )
        nativeProductionSessionIsActive = Self.currentSessionAllowsNativeActivation
        if nativeProductionSessionIsActive {
            resumeNativeProductionIfEligible()
        } else {
            NativeProductionTranslationCoordinator.shared
                .setLifecycleActivationAllowed(false, reason: .sessionResigned)
        }
        if !isLoginLaunch { showWindow() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationDidBecomeActive(_ notification: Notification) {
        model.applicationBecameActive()
        nativeProductionSessionIsActive = Self.currentSessionAllowsNativeActivation
        resumeNativeProductionIfEligible()
    }
    func applicationDidResignActive(_ notification: Notification) {
        model.applicationResignedActive()
    }
    func applicationWillTerminate(_ notification: Notification) {
        NativeProductionTranslationCoordinator.shared.invalidate(.terminate)
        NativeTranslationOverlayController.shared.shutdown()
        if model.onboardingPresented { model.deferOnboarding() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Closing a window does not enter this path; quitting stops
        // translation and the next launch stays paused.
        model.pauseForTermination()
        return .terminateNow
    }
    func windowWillClose(_ notification: Notification) {
        if model.onboardingPresented { model.deferOnboarding() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    private var launchedFromLogin: Bool {
        if ProcessInfo.processInfo.arguments.contains("--login-item") { return true }
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
    }
    private func createWindow() {
        let initialSize = model.onboardingPresented ? NSSize(width: 600, height: 560) : NSSize(width: 520, height: 520)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: initialSize), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "句译"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false; window.minSize = model.onboardingPresented ? NSSize(width: 560, height: 500) : NSSize(width: 520, height: 440); window.delegate = self
        ensureWindowVisible(forceCenter: true)
        window.contentView = NSHostingView(rootView: RootView(model: model))
        lastOnboardingMode = model.onboardingPresented
    }
    private func installMainMenu() {
        let main = NSMenu(), app = NSMenuItem(), submenu = NSMenu()
        let quit = NSMenuItem(title: quitMenuTitle, action: #selector(terminate), keyEquivalent: "q"); quit.target = self; submenu.addItem(quit)
        app.submenu = submenu; main.addItem(app); NSApp.mainMenu = main
    }
    private func item(_ title: String, action: Selector? = nil, enabled: Bool = true) -> NSMenuItem { let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self; i.isEnabled = enabled; return i }
    private var chromeSnapshot: AppChromeSnapshot {
        AppChromeSnapshot(
            summaryStatus: model.summaryStatus,
            statusSymbol: model.ready ? "character.bubble.fill" : model.summarySymbol,
            primaryActionTitle: model.primaryActionTitle,
            primaryActionEnabled: model.primaryActionEnabled,
            showsPauseItem: !model.ready && model.canPauseTranslation,
            selectedEngine: model.selectedEngine,
            engineMenuEnabled: !model.translationSetupInProgress && !model.cloudBusy,
            onboardingCompleted: model.onboardingCompleted
        )
    }
    private func updateMenu(_ snapshot: AppChromeSnapshot) {
        statusItem.button?.image = NSImage(systemSymbolName: snapshot.statusSymbol, accessibilityDescription: "句译 · \(snapshot.summaryStatus)")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "句译 · \(snapshot.summaryStatus)"
        let menu = NSMenu()
        menu.autoenablesItems = false
        // Six groups: status / window / engine / pause-resume / help / quit.
        menu.addItem(item("句译 · \(snapshot.summaryStatus)", enabled: false))
        menu.addItem(.separator())
        menu.addItem(item("打开句译…", action: #selector(showWindow)))
        menu.addItem(.separator())
        let engine = item("翻译方式")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let apple = item("本地翻译（Apple）", action: #selector(apple))
        apple.state = snapshot.selectedEngine == "apple" ? .on : .off
        let cloud = item("云端翻译（仅火山）…", action: #selector(cloud))
        cloud.state = snapshot.selectedEngine == "volc" ? .on : .off
        sub.addItem(apple); sub.addItem(cloud); engine.submenu = sub
        engine.isEnabled = snapshot.engineMenuEnabled
        menu.addItem(engine)
        menu.addItem(.separator())
        menu.addItem(item(snapshot.primaryActionTitle, action: #selector(primaryAction), enabled: snapshot.primaryActionEnabled))
        if snapshot.showsPauseItem {
            menu.addItem(item("暂停所有翻译", action: #selector(pause)))
        }
        menu.addItem(.separator())
        menu.addItem(item("诊断与帮助…", action: #selector(diagnostics)))
        menu.addItem(item("支持范围与隐私…", action: #selector(supportInfo)))
        menu.addItem(item(snapshot.onboardingCompleted ? "重新练习双 Option…" : "继续设置…", action: #selector(onboarding)))
        menu.addItem(.separator())
        let quit = item(quitMenuTitle, action: #selector(terminate))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        statusItem.menu = menu
    }
    private func updateChrome() {
        NativeTranslationOverlayController.shared.setPaused(model.userPaused)
        let snapshot = chromeSnapshot
        if chromeGate.needsRender(snapshot) { updateMenu(snapshot) }
        guard window != nil else { return }
        let mode = model.onboardingPresented
        guard lastOnboardingMode != mode else { return }
        lastOnboardingMode = mode
        window.minSize = mode ? NSSize(width: 560, height: 500) : NSSize(width: 520, height: 440)
        window.setContentSize(mode ? NSSize(width: 600, height: 560) : NSSize(width: 520, height: 520))
        ensureWindowVisible()
    }
    private func ensureWindowVisible(forceCenter: Bool = false) {
        let screens = NSScreen.screens
        let preferredScreen = forceCenter
            ? (NSScreen.main ?? screens.first)
            : (window.screen ?? NSScreen.main ?? screens.first)
        let adjusted = WindowFramePolicy.frameEnsuringVisibility(
            window.frame,
            in: screens.map(\.visibleFrame),
            preferredVisibleFrame: preferredScreen?.visibleFrame,
            forceCenter: forceCenter
        )
        if adjusted != window.frame { window.setFrame(adjusted, display: false) }
    }
    @objc private func showWindow() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        ensureWindowVisible()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func onboarding() {
        if model.onboardingCompleted {
            model.hotkeyReady ? model.relearnShortcut() : model.repairShortcut()
        } else {
            model.startOnboarding()
        }
        showWindow()
    }

    private func handleNativeOverlayCTA(_ cta: NativeTranslationOverlayCTA) {
        switch cta {
        case .openJuyi:
            showWindow()
        case .openDiagnostics:
            model.showDiagnostics = true
            showWindow()
        case .prepareAppleLanguages:
            showWindow()
            NativeProductionTranslationCoordinator.shared.prepareLanguages()
        case .checkCloudSettings:
            model.openCloudSettings()
            showWindow()
        case .chooseEngine:
            showWindow()
        }
    }
    @objc private func nativeProductionWillSleep(_ notification: Notification) {
        nativeProductionIsAwake = false
        NativeProductionTranslationCoordinator.shared
            .setLifecycleActivationAllowed(false, reason: .sleep)
    }
    @objc private func nativeProductionDidWake(_ notification: Notification) {
        nativeProductionIsAwake = true
        nativeProductionSessionIsActive = Self.currentSessionAllowsNativeActivation
        resumeNativeProductionIfEligible()
    }
    @objc private func nativeProductionSessionResigned(_ notification: Notification) {
        nativeProductionSessionIsActive = false
        NativeProductionTranslationCoordinator.shared
            .setLifecycleActivationAllowed(false, reason: .sessionResigned)
    }
    @objc private func nativeProductionSessionBecameActive(_ notification: Notification) {
        nativeProductionSessionIsActive = true
        resumeNativeProductionIfEligible()
    }
    private func resumeNativeProductionIfEligible() {
        guard nativeProductionIsAwake,
              nativeProductionSessionIsActive,
              Self.currentSessionAllowsNativeActivation else {
            NativeProductionTranslationCoordinator.shared
                .setLifecycleActivationAllowed(false, reason: .sessionResigned)
            return
        }
        let native = NativeProductionTranslationCoordinator.shared
        native.setLifecycleActivationAllowed(true)
        native.applicationBecameActive()
    }
    private static var currentSessionAllowsNativeActivation: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true else {
            return false
        }
        return true
    }
    @objc private func apple() {
        model.chooseApple()
    }
    @objc private func cloud() {
        model.chooseCloud(); showWindow()
    }
    @objc private func primaryAction() {
        model.performPrimaryAction()
        if !model.ready && !model.userPaused { showWindow() }
    }
    @objc private func supportInfo() { model.showSupportInfo = true; showWindow() }
    @objc private func pause() { model.togglePause() }; @objc private func diagnostics() { model.showDiagnostics = true; showWindow() }; @objc private func terminate() { NSApp.terminate(nil) }
}

@main enum JuyiMain {
    static func main() {
        if ProcessInfo.processInfo.arguments.contains("--unregister-login-item") {
            do {
                let service = SMAppService.mainApp
                if service.status != .notRegistered && service.status != .notFound {
                    try service.unregister()
                }
                exit(0)
            } catch {
                let message = Data("Unable to unregister the Juyi login item.\n".utf8)
                try? FileHandle.standardError.write(contentsOf: message)
                exit(1)
            }
        }
        let isLoginItemLaunch = ProcessInfo.processInfo.arguments.contains("--login-item")
        let duplicate = NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier)
            .first { $0.processIdentifier != getpid() }
        if let duplicate {
            if !isLoginItemLaunch { duplicate.activate(options: [.activateAllWindows]) }
            return
        }
        let app = NSApplication.shared, delegate = AppDelegate(); app.delegate = delegate; app.run()
    }
}
