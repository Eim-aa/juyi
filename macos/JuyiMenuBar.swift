import AppKit
import Combine
import CoreGraphics
import CryptoKit
import Darwin
import ServiceManagement
import SwiftUI

private let serviceLabel = "io.github.Eim-aa.argos-translator"
private let serviceURL = URL(string: "http://127.0.0.1:54321")!
private let appBundleIdentifier = "io.github.Eim-aa.Juyi"
private let fallbackLoginItemLabel = "io.github.Eim-aa.Juyi.login-item"
private let fallbackLoginItemExecutable = "/Applications/句译.app/Contents/MacOS/Juyi"
private let volcKeychainService = "io.github.Eim-aa.juyi.volc"
private let volcKeychainAccount = "volc"
private let volcPendingKeychainService = "io.github.Eim-aa.juyi.volc.pending"
private let volcPendingKeychainAccount = "pending"
private let shortcutDeploymentFingerprintDefaultsKey = "bundledShortcutDeploymentFingerprint"

struct Health: Decodable {
    let ok: Bool
    let auth_required: Bool?
    let default_engine: String?
    let engines: [String: Bool]
}

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

private enum EnvironmentFileRead: Equatable, Sendable {
    case found(Data)
    case notFound
    case unavailable
}

private enum CloudRemovalMarkerRead: Equatable {
    case present
    case notFound
    case unavailable
}

struct HotkeyStatus: Decodable {
    let module_loaded: Bool
    let accessibility: Bool
    let watcher_active: Bool
    let paused: Bool?
    let updated_at: Double?
    let owner_protocol_version: Int?
    let legacy_instance_id: String?
    let owner_state: String?
    let status_sequence: Int?
}

private struct TranslationResponse: Decodable {
    let result: String?
    let engine: String?
    let elapsed_ms: Int?
    let error: String?
    let warnings: [String]?
}

enum HotkeyProblem: Equatable {
    case notInstalled, notRunning, heartbeatExpired, needsUpdate, notAuthorized, notLoaded, paused, ready
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
    @Published private(set) var health: Health?
    @Published private(set) var hotkey: HotkeyStatus?
    @Published private(set) var selectedEngine = "apple"
    @Published private(set) var serviceBusy = false
    @Published private(set) var testing = false
    @Published private(set) var paused = false
    @Published private(set) var hasChecked = false
    @Published private(set) var appleNeedsPreparation = false
    @Published var testResult = ""
    @Published var testDetail = ""
    @Published var notice = ""
    @Published var showCloudSetup = false
    @Published var showDiagnostics = false
    @Published var showSupportInfo = false
    @Published var cloudBusy = false
    @Published var cloudError = ""
    @Published var onboardingPresented = false
    @Published var onboardingScreen: OnboardingScreen = .welcome
    @Published private(set) var onboardingEngineChecking = false
    @Published private(set) var onboardingEngineReady = false
    @Published private(set) var onboardingEngineResult = ""
    @Published private(set) var applePreparing = false
    @Published private(set) var loginItemState: LoginItemState = .notRegistered
    @Published private(set) var loginItemBusy = false
    @Published private(set) var loginItemNotice = ""
    @Published var permissionTroubleshooting = false
    @Published var practiceTroubleshooting = false
    @Published private(set) var shortcutRepairBusy = false

    var onChange: (() -> Void)?
    private var timer: Timer?
    private var nativeStateObservation: AnyCancellable?
    private var onboardingPreservesCompletion = false
    private var autoRepairAttempted = false
    private var loginItemMigrationInProgress = false
    private var loginItemBackend: LoginItemBackend = .serviceManagement
    private var localCloudCredentialFingerprint: String?
    private let loginItemRegistrationKey = "loginItemInitialRegistrationAttempted"
    private let hotkeyStatusReader = NativeOwnerHandoffStatusReader.live()
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var configDir: URL { home.appendingPathComponent(".config/argos-translator") }
    private var engineFile: URL { configDir.appendingPathComponent("hs-engine") }
    private var pauseFile: URL { configDir.appendingPathComponent("hs-paused") }
    private var envFile: URL { configDir.appendingPathComponent("volc.env") }
    private var authTokenFile: URL { configDir.appendingPathComponent("auth-token") }
    private var cloudRemovalMarker: URL { configDir.appendingPathComponent("cloud-removal-pending") }
    private var plist: URL { home.appendingPathComponent("Library/LaunchAgents/\(serviceLabel).plist") }
    private var fallbackLoginItemPlist: URL { home.appendingPathComponent("Library/LaunchAgents/\(fallbackLoginItemLabel).plist") }
    private var installRoot: URL {
        if let data = try? Data(contentsOf: plist),
           let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let dictionary = value as? [String: Any],
           let root = dictionary["WorkingDirectory"] as? String,
           root.hasPrefix("/") {
            return URL(fileURLWithPath: root, isDirectory: true)
        }
        return home.appendingPathComponent(".local/share/argos-translator", isDirectory: true)
    }
    private var helper: URL { installRoot.appendingPathComponent("bin/apple-translation-helper") }
    private var bundledShortcutModule: URL? {
        Bundle.main.url(forResource: "argos-translator", withExtension: "lua")
    }
    private var bundledShortcutDeploymentFingerprint: String? {
        guard let module = bundledShortcutModule,
              let data = try? Data(contentsOf: module),
              !data.isEmpty else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private var bundleIsInApplicationsFolder: Bool {
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath()
        let userApplications = home.appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        return bundleParent.path == "/Applications"
            || bundleParent.path == userApplications.path
    }
    private var bundledShortcutIsCurrent: Bool {
        guard let bundledModule = bundledShortcutModule,
              let fingerprint = bundledShortcutDeploymentFingerprint,
              UserDefaults.standard.string(
                forKey: shortcutDeploymentFingerprintDefaultsKey
              ) == fingerprint else { return false }
        let installedModule = home
            .appendingPathComponent(".hammerspoon", isDirectory: true)
            .appendingPathComponent("argos-translator.lua")
        guard let rawTarget = try? FileManager.default.destinationOfSymbolicLink(
            atPath: installedModule.path
        ) else { return false }
        let target = rawTarget.hasPrefix("/")
            ? URL(fileURLWithPath: rawTarget)
            : installedModule.deletingLastPathComponent().appendingPathComponent(rawTarget)
        return target.standardizedFileURL.resolvingSymlinksInPath()
            == bundledModule.standardizedFileURL.resolvingSymlinksInPath()
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
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configDir.path)
        // Preserve the user's preference. Existing development components
        // still require this exact bundle resource and a fresh legacy ack;
        // installations without those components use the native-only path.
        NativeProductionTranslationCoordinator.shared.setShortcutDeploymentReady(
            bundledShortcutIsCurrent
        )
        // A persisted removal transaction takes precedence over legacy
        // migration; never recreate an active credential while removal is
        // waiting to finish. Keychain commands are deliberately deferred so
        // the Apple-only startup path never waits on `security` on MainActor.
        let shouldMigrateLegacyCloud = readCloudRemovalMarker() == .notFound
        migrateOnboardingState()
        let explicitEngine = readExplicitEngineChoice()
        readLocalState()
        selectedEngine = OnboardingPolicy.preferredEngine(
            explicitEngine: explicitEngine,
            environmentEngine: readEnvironmentEngineChoice()
        )
        switch onboardingDisposition {
        case .neverStarted:
            onboardingScreen = .welcome; onboardingPresented = true
        case .inProgress:
            onboardingScreen = .permission; onboardingPresented = true
        case .deferred, .completed:
            onboardingPresented = false
        }
        configureDefaultLoginItemIfNeeded()
        // Hold the cloud-operation lock before the first scheduled task can
        // yield, so the setup UI cannot race crash recovery during launch.
        cloudBusy = true
        Task {
            if shouldMigrateLegacyCloud {
                await migrateLegacyCloudCredentialsIfNeeded()
            }
            localCloudCredentialFingerprint = credentialFingerprint(
                await readCloudCredentialsOffMainActor()
            )
            await recoverInterruptedCloudConfiguration()
            await refresh()
            if onboardingPresented && onboardingDisposition == .inProgress {
                onboardingScreen = firstIncompleteScreen()
            }
            if onboardingPresented && onboardingScreen == .prepare { verifyOnboardingEngine() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        nativeStateObservation = NativeProductionTranslationCoordinator.shared
            .objectWillChange.sink { [weak self] _ in
                Task { @MainActor in
                    self?.objectWillChange.send()
                    self?.onChange?()
                }
            }
    }

    var hammerspoonInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.hammerspoon.Hammerspoon") != nil
    }
    var hammerspoonRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "org.hammerspoon.Hammerspoon").isEmpty
    }
    var nativeNeedsLegacyHandoff: Bool {
        NativeProductionTranslationCoordinator.requiresLegacyHandoff
    }
    var serviceReady: Bool { health?.ok == true }
    var userPaused: Bool {
        paused && !NativeProductionTranslationCoordinator.shared.recoveryPauseHeld
    }
    var serviceInstalled: Bool { FileManager.default.fileExists(atPath: plist.path) }
    var appleHelperInstalled: Bool { FileManager.default.fileExists(atPath: helper.path) }
    var appleAvailable: Bool { health?.engines["apple"] == true }
    var cloudConfigured: Bool { health?.engines["volc"] == true }
    var cloudConfigExists: Bool { localCloudCredentialFingerprint != nil }
    var hotkeyReady: Bool {
        selectedEngine == "apple"
            ? NativeProductionTranslationCoordinator.shared.isEnabled
            : hotkeyProblem == .ready
    }
    var nativeOwnerBridgeReady: Bool {
        guard let hotkey,
              hotkey.module_loaded,
              hotkey.owner_protocol_version == NativeOwnerHandoffProtocol.version,
              let instanceText = hotkey.legacy_instance_id,
              let instance = UUID(uuidString: instanceText),
              instance.uuidString.lowercased() == instanceText.lowercased(),
              let sequence = hotkey.status_sequence,
              sequence > 0,
              let updated = hotkey.updated_at,
              updated.isFinite else { return false }
        let age = Date().timeIntervalSince1970 - updated
        return age >= -NativeOwnerHandoffProtocol.maximumFutureClockSkew
            && age < 6
    }
    var hotkeyProblem: HotkeyProblem {
        if NativeProductionTranslationCoordinator.shared.isEnabled {
            return .ready
        }
        if !hammerspoonInstalled { return .notInstalled }
        if !hammerspoonRunning { return .notRunning }
        guard let hotkey, let updated = hotkey.updated_at,
              updated.isFinite else { return .heartbeatExpired }
        let age = Date().timeIntervalSince1970 - updated
        guard age >= -NativeOwnerHandoffProtocol.maximumFutureClockSkew,
              age < 6 else { return .heartbeatExpired }
        guard hotkey.owner_protocol_version == NativeOwnerHandoffProtocol.version,
              let instanceText = hotkey.legacy_instance_id,
              let instance = UUID(uuidString: instanceText),
              instance.uuidString.lowercased() == instanceText.lowercased(),
              let sequence = hotkey.status_sequence,
              sequence > 0 else { return .needsUpdate }
        if hotkey.accessibility != true { return .notAuthorized }
        if paused || hotkey.paused == true { return .paused }
        if hotkey.module_loaded != true || hotkey.watcher_active != true { return .notLoaded }
        return .ready
    }
    var engineReady: Bool {
        selectedEngine == "apple"
            ? NativeProductionTranslationCoordinator.shared.isEnabled
            : (cloudConfigured && cloudVerified)
    }
    var onboardingCompleted: Bool { onboardingDisposition == .completed }
    var ready: Bool {
        if selectedEngine == "apple" {
            return !paused && NativeProductionTranslationCoordinator.shared.isEnabled
        }
        return !paused && serviceReady && hotkeyReady && engineReady && onboardingCompleted
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
        if selectedEngine == "apple" {
            let native = NativeProductionTranslationCoordinator.shared
            if shortcutRepairBusy { return "正在准备快捷键…" }
            if native.isPreparingLanguages { return "正在准备语言包…" }
            switch native.phase {
            case .active: return "句译已就绪"
            case .requestingAccessibility: return "请允许辅助功能"
            case .waitingForHammerspoon: return "正在启用双 Option…"
            case .languagePackRequired: return "还需准备语言包"
            case .unsupported: return "此设备暂不支持离线翻译"
            case .disabled: return "启用后即可翻译"
            case .unavailable: return "快捷键需要处理"
            }
        }
        if ready { return "句译已就绪" }
        if !serviceReady { return "句译需要处理" }
        return "还差一步"
    }
    var statusMessage: String {
        if !hasChecked { return "这通常只需要几秒。" }
        if userPaused { return "恢复后即可继续使用双击 Option 翻译。" }
        if selectedEngine == "apple" {
            let native = NativeProductionTranslationCoordinator.shared
            if native.isEnabled { return "选中英文，连按两次 Option，查看中文译文。" }
            if shortcutRepairBusy { return "正在更新兼容组件，请稍候。" }
            return native.detail
        }
        if !serviceReady { return serviceBusy ? "正在重新连接翻译组件…" : "翻译组件暂时没有响应，可以自动修复。" }
        if !engineReady { return selectedEngine == "volc" ? "验证云端连接后即可开始使用。" : "需要准备 Apple 离线翻译。" }
        switch hotkeyProblem {
        case .notInstalled: return "需要先安装 Hammerspoon 快捷键助手。"
        case .notRunning: return "Hammerspoon 尚未运行，请打开它。"
        case .heartbeatExpired: return "快捷键助手没有响应，请重新打开 Hammerspoon。"
        case .needsUpdate: return "快捷键模块需要更新，请让句译部署当前版本并重新载入。"
        case .notAuthorized: return "请在辅助功能中允许 Hammerspoon。"
        case .notLoaded: return "快捷键配置尚未载入，请在 Hammerspoon 中重新载入配置。"
        case .paused: return "恢复后即可继续使用双击 Option 翻译。"
        case .ready: break
        }
        if !onboardingCompleted { return "最后试一次双击 Option，确认译文能够出现。" }
        return "选中英文，快速连按两次 Option。"
    }
    var statusSymbol: String {
        if !hasChecked { return "ellipsis.circle.fill" }
        if userPaused { return "pause.circle.fill" }
        if ready { return "checkmark.circle.fill" }
        return selectedEngine == "apple" || serviceReady
            ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill"
    }
    var statusColor: Color {
        if !hasChecked { return .secondary }
        if userPaused { return .secondary }
        if ready { return Color(nsColor: .systemGreen) }
        return selectedEngine == "apple" || serviceReady
            ? Color(nsColor: .systemOrange) : Color(nsColor: .systemRed)
    }

    // Presentation only: reuse the existing owner, pause and readiness state.
    // A disabled native path does not imply the legacy watcher has stopped.
    var translationSetupInProgress: Bool {
        let native = NativeProductionTranslationCoordinator.shared
        return !hasChecked || shortcutRepairBusy || native.isPreparingLanguages
            || (selectedEngine == "apple" && (native.phase == .requestingAccessibility
                || native.phase == .waitingForHammerspoon))
            || (selectedEngine == "volc" && (serviceBusy || cloudBusy))
    }
    var canPauseTranslation: Bool {
        !userPaused && (NativeProductionTranslationCoordinator.shared.isEnabled
            || hotkey?.watcher_active == true || translationSetupInProgress)
    }
    var summaryStatus: String {
        if userPaused { return "已暂停" }
        if translationSetupInProgress { return "设置中" }
        if ready { return "已就绪" }
        if selectedEngine == "apple"
            && NativeProductionTranslationCoordinator.shared.phase == .disabled {
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
        if shortcutRepairBusy { return "正在准备兼容组件…" }
        if native.isPreparingLanguages { return "正在准备语言包…" }
        if selectedEngine == "apple" {
            if native.phase == .requestingAccessibility { return "打开系统设置" }
            if native.phase == .waitingForHammerspoon { return "正在启用双 Option…" }
            if native.phase == .languagePackRequired { return "准备语言包" }
            if native.phase == .unsupported { return "诊断与帮助" }
            if native.phase == .unavailable { return "重新检查并启用" }
            return onboardingCompleted ? "启用双 Option" : "继续设置"
        }
        if serviceBusy || cloudBusy { return "正在检查云端…" }
        if !serviceReady { return "修复云端组件" }
        if !engineReady { return "设置火山云端" }
        if !hammerspoonInstalled { return "下载 Hammerspoon" }
        return "检查快捷键设置"
    }
    var primaryActionEnabled: Bool {
        if userPaused || ready { return true }
        let native = NativeProductionTranslationCoordinator.shared
        if !hasChecked || shortcutRepairBusy || native.isPreparingLanguages { return false }
        if selectedEngine == "apple" {
            return native.phase == .requestingAccessibility || native.actionIsEnabled
        }
        return !serviceBusy && !cloudBusy
    }
    func performPrimaryAction() {
        guard primaryActionEnabled else { return }
        let native = NativeProductionTranslationCoordinator.shared
        if userPaused || ready { togglePause(); return }
        if selectedEngine == "apple" {
            if native.phase == .requestingAccessibility { openAccessibility() }
            else if native.phase == .languagePackRequired { native.prepareLanguages() }
            else if native.phase == .unsupported { showDiagnostics = true }
            else if native.phase == .unavailable || onboardingCompleted { enableNativeShortcut() }
            else { startOnboarding() }
        } else if !serviceReady { repairService() }
        else if !engineReady { chooseCloud() }
        else if !hammerspoonInstalled { openHammerspoon() }
        else { showDiagnostics = true }
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
        if onboardingScreen == .prepare { verifyOnboardingEngine() }
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
        autoRepairAttempted = false
        onboardingEngineReady = false
        onboardingEngineResult = ""
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
        case .prepare:
            guard onboardingEngineReady else { return }
            onboardingScreen = .permission
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

    func verifyOnboardingEngine() {
        guard !onboardingEngineChecking else { return }
        guard serviceReady else {
            onboardingEngineReady = false
            onboardingEngineResult = ""
            if serviceInstalled && !autoRepairAttempted {
                autoRepairAttempted = true
                repairService()
            }
            return
        }
        guard engineReady else {
            onboardingEngineReady = false
            onboardingEngineResult = ""
            return
        }
        onboardingEngineChecking = true
        onboardingEngineResult = ""
        let engine = selectedEngine
        Task {
            let response = await translate("Good tools should feel effortless.", engine: engine)
            onboardingEngineChecking = false
            onboardingEngineReady = response?.error == nil && response?.engine == engine && !(response?.result ?? "").isEmpty
            onboardingEngineResult = onboardingEngineReady ? (response?.result ?? "") : ""
            appleNeedsPreparation = response?.error == "apple_error"
            if onboardingEngineReady { announce(engine == "apple" ? "Apple 离线翻译已准备好" : "火山云端翻译已准备好") }
        }
    }

    func retryOnboardingEngine() {
        autoRepairAttempted = false
        onboardingEngineReady = false
        verifyOnboardingEngine()
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
        if selectedEngine == "apple" && !nativeNeedsLegacyHandoff {
            enableNativeShortcut()
        } else {
            installBundledShortcut(enableNativeAfterInstall: false)
        }
        onChange?()
    }

    func enableNativeShortcut() {
        notice = ""
        let native = NativeProductionTranslationCoordinator.shared
        guard bundleIsInApplicationsFolder else {
            notice = "请先把句译拖到“应用程序”文件夹，再启用双 Option。"
            return
        }
        guard selectedEngine == "apple" || setEngine("apple") else { return }
        if native.isEnabled {
            native.enableByUser()
            return
        }
        readLocalState()
        if !nativeNeedsLegacyHandoff {
            native.enableByUser()
            return
        }
        let deploymentIsCurrent = bundledShortcutIsCurrent
        native.setShortcutDeploymentReady(deploymentIsCurrent)
        if nativeOwnerBridgeReady && deploymentIsCurrent {
            native.enableByUser()
            return
        }
        installBundledShortcut(enableNativeAfterInstall: true)
    }

    private func installBundledShortcut(enableNativeAfterInstall: Bool) {
        guard !shortcutRepairBusy else { return }
        guard hammerspoonInstalled else {
            notice = "请先安装 Hammerspoon；安装后句译会自动部署当前快捷键模块。"
            return
        }
        guard bundleIsInApplicationsFolder else {
            notice = "请先把句译拖到“应用程序”文件夹，再启用双 Option。"
            return
        }
        guard let hook = Bundle.main.url(
            forResource: "hammerspoon_hook", withExtension: "sh"
        ), let deploymentFingerprint = bundledShortcutDeploymentFingerprint else {
            notice = "这个句译安装包缺少快捷键模块，请重新下载。"
            return
        }

        readLocalState()
        let previousOwnerInstanceID = canonicalOwnerInstanceID(hotkey)
        let previousOwnerUpdatedAt = hotkey?.updated_at
        NativeProductionTranslationCoordinator.shared
            .setShortcutDeploymentReady(false)
        shortcutRepairBusy = true
        notice = "正在安全部署当前快捷键模块并重新启动 Hammerspoon…"
        let hookPath = hook.path
        Task {
            let code = await Task.detached { () -> Int32 in
                for command in ["check", "install"] {
                    let result = Self.runHammerspoonHook(
                        path: hookPath, command: command
                    )
                    if result != 0 { return result }
                }
                return 0
            }.value
            let restartStartedAt = Date().timeIntervalSince1970
            let hammerspoonRestarted = code == 0
                ? await restartHammerspoonAfterInstall()
                : false

            var deployedOwnerReady = false
            var fallbackCandidateInstanceID: String?
            var fallbackCandidateSequence: Int?
            if code == 0 && hammerspoonRestarted {
                for _ in 0..<30 {
                    try? await Task.sleep(for: .milliseconds(200))
                    readLocalState()
                    if ownerBridgeIsFreshAfterRestart(
                        previousInstanceID: previousOwnerInstanceID,
                        previousUpdatedAt: previousOwnerUpdatedAt,
                        restartStartedAt: restartStartedAt,
                        fallbackCandidateInstanceID: &fallbackCandidateInstanceID,
                        fallbackCandidateSequence: &fallbackCandidateSequence
                    ) {
                        deployedOwnerReady = true
                        break
                    }
                }
            }
            shortcutRepairBusy = false
            if code != 0 {
                notice = "快捷键模块未能完成部署；句译不会覆盖自定义普通文件。请检查 Hammerspoon 配置后重试。"
            } else if !hammerspoonRestarted {
                notice = "模块已部署，但无法自动重新启动 Hammerspoon。请手动退出并重新打开 Hammerspoon。"
            } else if deployedOwnerReady {
                UserDefaults.standard.set(
                    deploymentFingerprint,
                    forKey: shortcutDeploymentFingerprintDefaultsKey
                )
                notice = "当前快捷键模块已载入。"
                let native = NativeProductionTranslationCoordinator.shared
                native.setShortcutDeploymentReady(true)
                if enableNativeAfterInstall && !native.isEnabled {
                    native.enableByUser()
                } else {
                    native.resumeIfEnabled()
                }
            } else {
                notice = "模块已部署，但 Hammerspoon 尚未完成重新载入，请打开它后再试。"
            }
            onChange?()
        }
    }

    private func canonicalOwnerInstanceID(_ status: HotkeyStatus?) -> String? {
        guard let text = status?.legacy_instance_id,
              let value = UUID(uuidString: text),
              value.uuidString.lowercased() == text.lowercased() else { return nil }
        return value.uuidString.lowercased()
    }

    private func ownerBridgeIsFreshAfterRestart(
        previousInstanceID: String?,
        previousUpdatedAt: TimeInterval?,
        restartStartedAt: TimeInterval,
        fallbackCandidateInstanceID: inout String?,
        fallbackCandidateSequence: inout Int?
    ) -> Bool {
        guard nativeOwnerBridgeReady,
              let currentInstanceID = canonicalOwnerInstanceID(hotkey),
              let updatedAt = hotkey?.updated_at,
              let currentSequence = hotkey?.status_sequence else { return false }
        if let previousInstanceID {
            return currentInstanceID != previousInstanceID
                && updatedAt >= floor(restartStartedAt)
        }
        // With no trustworthy previous UUID, wait past the restart second.
        // Lua timestamps have one-second precision, so this excludes a stale
        // status written just before restart in the same wall-clock second.
        guard updatedAt >= ceil(restartStartedAt) else { return false }
        if let previousUpdatedAt, updatedAt <= previousUpdatedAt { return false }
        if fallbackCandidateInstanceID == currentInstanceID,
           let candidateSequence = fallbackCandidateSequence,
           currentSequence > candidateSequence {
            return true
        }
        fallbackCandidateInstanceID = currentInstanceID
        fallbackCandidateSequence = currentSequence
        return false
    }

    private func restartHammerspoonAfterInstall() async -> Bool {
        let bundleIdentifier = "org.hammerspoon.Hammerspoon"
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else { return false }

        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        if !running.isEmpty {
            for application in running {
                _ = application.terminate()
            }
            for _ in 0..<15 {
                if running.allSatisfy({ $0.isTerminated }) { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard running.allSatisfy({ $0.isTerminated }) else { return false }
        }

        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
        for _ in 0..<15 {
            if !NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    func applicationBecameActive() {
        refreshLoginItemState()
        migrateFallbackToServiceManagementIfNeeded()
        Task {
            await refresh()
            if onboardingPresented && onboardingScreen == .prepare { verifyOnboardingEngine() }
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

    private func readLocalState() {
        let previousEngine = selectedEngine
        let wasPaused = paused
        if let value = readExplicitEngineChoice() {
            selectedEngine = value
        }
        paused = ((try? String(contentsOf: pauseFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        if selectedEngine != previousEngine {
            NativeProductionTranslationCoordinator.shared
                .setAppleEngineSelected(selectedEngine == "apple")
        }
        if paused != wasPaused {
            NativeProductionTranslationCoordinator.shared.setPaused(paused)
        }
        if let hotkeyStatusReader,
           case let .present(data) = hotkeyStatusReader.read(),
           let decoded = try? JSONDecoder().decode(HotkeyStatus.self, from: data) {
            hotkey = decoded
        } else {
            hotkey = nil
        }
    }

    private func readExplicitEngineChoice() -> String? {
        guard let value = try? String(contentsOf: engineFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              ["apple", "volc"].contains(value) else { return nil }
        return value
    }

    private func readEnvironmentEngineChoice() -> String? {
        guard let engine = readEnvironmentValues()["ENGINE"], ["apple", "volc"].contains(engine) else { return nil }
        return engine
    }

    private func readEnvironmentValues() -> [String: String] {
        guard let text = try? String(contentsOf: envFile, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value.removeFirst(); value.removeLast()
            }
            values[key] = value
        }
        return values
    }

    private func readLegacyCloudCredentials() -> CloudCredentials? {
        let values = readEnvironmentValues()
        guard let access = values["VOLC_ACCESS_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let secret = values["VOLC_SECRET_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !access.isEmpty, !secret.isEmpty else { return nil }
        return CloudCredentials(accessKey: access, secretKey: secret)
    }

    private func readCloudCredentials() -> CloudCredentials? {
        switch AppModel.readKeychainCloudCredentials() {
        case .found(let credentials): return credentials
        case .notFound: return readLegacyCloudCredentials()
        case .invalid, .unavailable: return nil
        }
    }

    private func readCloudCredentialsOffMainActor() async -> CloudCredentials? {
        let keychainState = await Task.detached {
            AppModel.readKeychainCloudCredentials()
        }.value
        switch keychainState {
        case .found(let credentials): return credentials
        case .notFound: return readLegacyCloudCredentials()
        case .invalid, .unavailable: return nil
        }
    }

    private func credentialFingerprint(_ credentials: CloudCredentials?) -> String? {
        guard let credentials else { return nil }
        var data = Data(credentials.accessKey.utf8)
        data.append(0)
        data.append(contentsOf: credentials.secretKey.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func environmentKey(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else { return nil }
        return String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeEnvironmentWithoutSecrets(engine: String?) throws {
        let original: String
        do {
            original = try String(contentsOf: envFile, encoding: .utf8)
        } catch {
            guard !FileManager.default.fileExists(atPath: envFile.path) else { throw error }
            original = ""
        }
        var lines = original.components(separatedBy: "\n")
        while lines.last == "" { lines.removeLast() }
        lines.removeAll { line in
            guard let key = environmentKey(in: line) else { return false }
            if key == "VOLC_ACCESS_KEY" || key == "VOLC_SECRET_KEY" { return true }
            return engine != nil && key == "ENGINE"
        }
        if let engine { lines.append("ENGINE=\(engine)") }
        let output = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try output.write(to: envFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envFile.path)
    }

    private func readEnvironmentFile() -> EnvironmentFileRead {
        do {
            return .found(try Data(contentsOf: envFile))
        } catch {
            return FileManager.default.fileExists(atPath: envFile.path) ? .unavailable : .notFound
        }
    }

    private func readCloudRemovalMarker() -> CloudRemovalMarkerRead {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: cloudRemovalMarker.path)) != nil {
            return .unavailable
        }
        guard FileManager.default.fileExists(atPath: cloudRemovalMarker.path) else { return .notFound }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: cloudRemovalMarker.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              permissions & 0o077 == 0,
              let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
              owner == getuid(),
              let data = try? Data(contentsOf: cloudRemovalMarker),
              data == Data("1\n".utf8) else { return .unavailable }
        return .present
    }

    private func createCloudRemovalMarker() -> Bool {
        switch readCloudRemovalMarker() {
        case .present:
            return true
        case .unavailable:
            return false
        case .notFound:
            break
        }
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: configDir.path)) != nil {
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: configDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configDir.path)
        } catch {
            return false
        }

        var descriptor = cloudRemovalMarker.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            return errno == EEXIST && readCloudRemovalMarker() == .present
        }

        var keepMarker = false
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            if !keepMarker { try? FileManager.default.removeItem(at: cloudRemovalMarker) }
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else { return false }
        let payload = Array("1\n".utf8)
        let wrotePayload = payload.withUnsafeBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wrotePayload, Darwin.fsync(descriptor) == 0 else { return false }
        let closeResult = Darwin.close(descriptor)
        descriptor = -1
        guard closeResult == 0 else { return false }
        guard readCloudRemovalMarker() == .present else { return false }
        keepMarker = true
        return true
    }

    private func deleteCloudRemovalMarker() -> Bool {
        switch readCloudRemovalMarker() {
        case .notFound:
            return true
        case .unavailable:
            return false
        case .present:
            do {
                try FileManager.default.removeItem(at: cloudRemovalMarker)
                return readCloudRemovalMarker() == .notFound
            } catch {
                return false
            }
        }
    }

    @discardableResult private func restoreEnvironment(_ backup: EnvironmentFileRead) -> Bool {
        do {
            switch backup {
            case .found(let data):
                try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
                try data.write(to: envFile, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envFile.path)
            case .notFound:
                if FileManager.default.fileExists(atPath: envFile.path) {
                    try FileManager.default.removeItem(at: envFile)
                }
            case .unavailable:
                return false
            }
            return true
        } catch {
            return false
        }
    }

    private func migrateLegacyCloudCredentialsIfNeeded() async {
        guard let legacy = readLegacyCloudCredentials() else { return }
        guard case .found(let oldEnvironment) = readEnvironmentFile() else { return }
        let oldEnvironmentFingerprint = SHA256.hash(data: oldEnvironment).map { String(format: "%02x", $0) }.joined()
        let legacyWasVerified = oldEnvironmentFingerprint == UserDefaults.standard.string(forKey: "cloudVerifiedFingerprint")
        let keychainState = await Task.detached {
            AppModel.readKeychainCloudCredentials()
        }.value
        let activeCredentials: CloudCredentials
        switch keychainState {
        case .found(let credentials):
            activeCredentials = credentials
        case .notFound:
            let saved = await Task.detached {
                AppModel.saveKeychainCloudCredentials(legacy)
                    && AppModel.readKeychainCloudCredentials() == .found(legacy)
            }.value
            guard saved else { return }
            activeCredentials = legacy
        case .invalid, .unavailable:
            // Never overwrite an item that merely could not be read.
            return
        }
        do {
            try writeEnvironmentWithoutSecrets(engine: nil)
            if legacyWasVerified, activeCredentials == legacy, let fingerprint = credentialFingerprint(activeCredentials) {
                UserDefaults.standard.set(fingerprint, forKey: "cloudVerifiedFingerprint")
            }
        } catch {
            // Keep both copies if cleanup fails. A migration must never destroy
            // the only usable credential set.
        }
    }

    private func authenticatedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let token = try? String(contentsOf: authTokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           token.utf8.count == 64,
           token.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func refresh() async {
        readLocalState()
        var request = authenticatedRequest(url: serviceURL.appendingPathComponent("health")); request.timeoutInterval = 1.4
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 { health = try JSONDecoder().decode(Health.self, from: data) }
            else { health = nil }
        } catch { health = nil }
        hasChecked = true
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

    nonisolated private static func runHammerspoonHook(
        path: String,
        command: String
    ) -> Int32 {
        runBoundedProcess(
            executablePath: "/bin/bash",
            arguments: [path, command],
            timeout: .seconds(8)
        ).status
    }

    nonisolated private static func launchctlPID(from output: String) -> pid_t? {
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("pid = ") else { continue }
            let value = line.dropFirst("pid = ".count)
            if let pid = pid_t(value), pid > 1 { return pid }
        }
        return nil
    }

    nonisolated private static func processExists(_ pid: pid_t) -> Bool {
        errno = 0
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno != ESRCH
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

    nonisolated private static func restoreKeychainCloudCredentials(
        _ state: CloudCredentialRead,
        service: String = volcKeychainService,
        account: String = volcKeychainAccount
    ) -> Bool {
        switch state {
        case .found(let credentials):
            return saveKeychainCloudCredentials(credentials, service: service, account: account)
                && readKeychainCloudCredentials(service: service, account: account) == .found(credentials)
        case .notFound:
            return deleteKeychainCloudCredentials(service: service, account: account)
        case .invalid, .unavailable:
            return false
        }
    }

    nonisolated private static func savePendingCloudCredentials(_ credentials: CloudCredentials) -> Bool {
        saveKeychainCloudCredentials(
            credentials,
            service: volcPendingKeychainService,
            account: volcPendingKeychainAccount
        ) && readKeychainCloudCredentials(
            service: volcPendingKeychainService,
            account: volcPendingKeychainAccount
        ) == .found(credentials)
    }

    nonisolated private static func deletePendingCloudCredentials() -> Bool {
        deleteKeychainCloudCredentials(
            service: volcPendingKeychainService,
            account: volcPendingKeychainAccount
        )
    }

    nonisolated private static func deletePendingCloudCredentials(
        matching candidate: CloudCredentials
    ) -> Bool {
        let state = readKeychainCloudCredentials(
            service: volcPendingKeychainService,
            account: volcPendingKeychainAccount
        )
        switch state {
        case .notFound:
            return true
        case .found(let stored) where stored == candidate:
            return deletePendingCloudCredentials()
        case .found, .invalid, .unavailable:
            return false
        }
    }

    func repairService() {
        guard !serviceBusy, !cloudBusy else { return }; serviceBusy = true; notice = ""
        guard serviceInstalled else {
            serviceBusy = false
            notice = "句译安装不完整。请打开安装说明，并按当前步骤重新安装。"
            showDiagnostics = true
            return
        }
        let target = plist.path
        Task {
            _ = await Task.detached { () -> (Int32, String) in
                let domain = "gui/\(getuid())"
                let serviceTarget = "\(domain)/\(serviceLabel)"
                let kickstart = AppModel.launchctl(["kickstart", "-k", serviceTarget])
                if kickstart.0 == 0 { return kickstart }

                // A failed kickstart normally means the label is not loaded.
                // Bootstrap without unloading anything: another process may
                // have loaded the service between these calls.
                let bootstrap = AppModel.launchctl(["bootstrap", domain, target])
                let retry = AppModel.launchctl(["kickstart", "-k", serviceTarget])
                return retry.0 == 0 ? retry : bootstrap
            }.value
            try? await Task.sleep(for: .seconds(1.2)); await refresh(); serviceBusy = false
            if !serviceReady { notice = "自动修复没有完成，请打开“诊断与帮助”查看下一步。" }
            if onboardingPresented && onboardingScreen == .prepare { verifyOnboardingEngine() }
        }
    }

    func chooseApple() {
        guard !cloudBusy else { notice = "云端设置正在安全处理，请稍候。"; return }
        if setEngine("apple") { notice = "已选择 Apple 离线。启用双 Option 后即可翻译。" }
    }

    func repairCurrentTranslation() {
        guard selectedEngine == "apple" else { repairService(); return }
        let native = NativeProductionTranslationCoordinator.shared
        if native.phase == .languagePackRequired {
            native.prepareLanguages()
        } else if native.isEnabled {
            native.retryByUser()
        } else {
            enableNativeShortcut()
        }
    }
    func chooseCloud() {
        guard !cloudBusy else { notice = "云端设置正在安全处理，请稍候。"; return }
        guard serviceReady else { notice = "请先恢复翻译组件，再选择翻译方式。"; repairService(); return }
        if cloudConfigured && cloudVerified {
            if setEngine("volc") { notice = "已切换到火山云端翻译。" }
        }
        else if cloudConfigured { validateExistingCloud() }
        else { cloudError = ""; showCloudSetup = true }
    }
    @discardableResult private func setEngine(_ engine: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try "\(engine)\n".write(to: engineFile, atomically: true, encoding: .utf8)
            selectedEngine = engine
            NativeProductionTranslationCoordinator.shared
                .setAppleEngineSelected(engine == "apple")
            #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
            NativeTranslationAppleResultLabLive.shared.invalidate(.engineChanged)
            #elseif DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
            NativeAppleTranslationAdapterCoordinator.shared.invalidate(.engineChanged)
            #endif
            #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
            NativeVolcTranslationAdapterCoordinator.shared.invalidate(.engineChanged)
            #endif
            onChange?()
            return true
        } catch {
            notice = "暂时无法保存选择，请稍后重试。"
            return false
        }
    }

    /// A pending item is the durable transaction marker for cloud setup. It is
    /// kept until the promoted credential has survived a service restart and a
    /// real translation. After a crash, either finish that promotion or discard
    /// a candidate that never became active; never guess through Keychain errors.
    private func recoverInterruptedCloudConfiguration() async {
        // init() acquires this lock synchronously before scheduling recovery.
        defer { cloudBusy = false }
        switch readCloudRemovalMarker() {
        case .unavailable:
            _ = setEngine("apple")
            let stopped = await stopServiceAndConfirm(allowAlreadyStopped: true)
            notice = stopped
                ? "检测到无法验证的云端移除标记；后台服务已停止，请打开“诊断与帮助”。"
                : "检测到无法验证的云端移除标记，且无法确认后台服务已停止；云端请求已被安全阻断。"
            return
        case .present:
            guard await finishInterruptedCloudRemoval() else { return }
        case .notFound:
            break
        }
        let pending = await Task.detached {
            AppModel.readKeychainCloudCredentials(
                service: volcPendingKeychainService,
                account: volcPendingKeychainAccount
            )
        }.value
        switch pending {
        case .notFound:
            return
        case .invalid, .unavailable:
            notice = "检测到未完成的云端设置，但暂时无法读取。请解锁钥匙串后重新打开句译。"
            return
        case .found(let candidate):
            let active = await Task.detached {
                AppModel.readKeychainCloudCredentials()
            }.value
            switch active {
            case .invalid, .unavailable:
                notice = "检测到未完成的云端设置，但暂时无法确认原配置。请解锁钥匙串后重试。"
                return
            case .notFound:
                guard await startServiceAndWait() else {
                    notice = "未完成的云端设置仍在安全保留；后台恢复后会继续清理。"
                    return
                }
                let cleaned = await Task.detached {
                    AppModel.deletePendingCloudCredentials(matching: candidate)
                }.value
                if !cleaned { notice = "未完成的云端设置暂时无法清理，请稍后重新打开句译。" }
                return
            case .found(let activeCredentials) where activeCredentials != candidate:
                guard await startServiceAndWait() else {
                    notice = "旧云端配置尚未重新载入；事务标记会保留到后台恢复成功。"
                    return
                }
                let cleaned = await Task.detached {
                    AppModel.deletePendingCloudCredentials(matching: candidate)
                }.value
                if !cleaned { notice = "旧的云端设置草稿暂时无法清理，请稍后重新打开句译。" }
                return
            case .found:
                break
            }

            do {
                try writeEnvironmentWithoutSecrets(engine: "volc")
            } catch {
                notice = "云端设置恢复尚未完成；凭据仍安全保存在钥匙串中，请稍后重新打开句译。"
                return
            }
            guard await startServiceAndWait(expectCloud: true) else {
                notice = "云端设置恢复尚未完成；句译会在下次启动时继续，不会丢失凭据。"
                return
            }
            let validation = await translate("Good tools should feel effortless.", engine: "volc")
            guard validation?.error == nil,
                  validation?.engine == "volc",
                  !(validation?.result ?? "").isEmpty else {
                notice = "云端设置恢复后未通过翻译验证，请打开“诊断与帮助”。"
                return
            }
            localCloudCredentialFingerprint = credentialFingerprint(candidate)
            cloudVerified = true
            guard setEngine("volc") else {
                notice = "云端已验证，但暂时无法保存翻译方式；请稍后重新选择火山云端。"
                return
            }
            let cleaned = await Task.detached {
                AppModel.deletePendingCloudCredentials(matching: candidate)
            }.value
            notice = cleaned
                ? "已恢复上次中断的云端设置。"
                : "云端已恢复；安全清理会在下次启动时继续。"
            await refresh()
        }
    }

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
            guard let credentials = readCloudCredentials() else {
                notice = "云端设置不完整，请重新配置。"
                showCloudSetup = true
                return
            }
            // Credentials stay in Keychain. Validation exercises the already
            // running service with an ordinary translation request, so AK/SK
            // never cross the unauthenticated loopback transport.
            let response = await translate("Good tools should feel effortless.", engine: "volc")
            guard credentialFingerprint(readCloudCredentials()) == credentialFingerprint(credentials) else {
                cloudVerified = false
                notice = "验证期间云端配置已变化，请重新运行验证。"
                announce(notice)
                return
            }
            if response?.error == nil, response?.engine == "volc", !(response?.result ?? "").isEmpty {
                localCloudCredentialFingerprint = credentialFingerprint(credentials)
                cloudVerified = true
                notice = setEngine("volc")
                    ? "云端连接验证成功，已切换到火山云端。"
                    : "云端连接已验证，但暂时无法保存翻译方式。"
                announce(notice)
                if onboardingPresented && onboardingScreen == .prepare { verifyOnboardingEngine() }
            } else { cloudVerified = false; notice = friendlyError(response); announce(notice) }
        }
    }

    func configureCloud(accessKey: String, secretKey: String) {
        guard !cloudBusy else { return }
        let access = accessKey.trimmingCharacters(in: .whitespacesAndNewlines), secret = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !access.isEmpty, !secret.isEmpty, !access.contains("\n"), !secret.contains("\n") else { cloudError = "请完整填写两项访问密钥。"; return }
        cloudBusy = true; cloudError = ""
        let candidate = CloudCredentials(accessKey: access, secretKey: secret)
        let environmentBackup = readEnvironmentFile()
        guard environmentBackup != .unavailable else {
            cloudBusy = false
            cloudError = "暂时无法读取旧的云端设置文件，原配置未更改。"
            return
        }
        let keychainBackup = AppModel.readKeychainCloudCredentials()
        guard keychainBackup != .invalid, keychainBackup != .unavailable else {
            cloudBusy = false
            cloudError = "暂时无法读取 macOS 钥匙串，原有云端配置未更改。请解锁钥匙串后重试。"
            return
        }
        let verifiedFingerprintBackup = UserDefaults.standard.string(forKey: "cloudVerifiedFingerprint")
        Task {
            var pendingWriteAttempted = false
            var activeWriteAttempted = false
            var environmentWriteAttempted = false
            do {
                pendingWriteAttempted = true
                let pendingSaved = await Task.detached {
                    AppModel.savePendingCloudCredentials(candidate)
                }.value
                guard pendingSaved else { throw NSError(domain: "Juyi", code: 1) }
                let pendingValidation = await validatePendingCloud()
                guard pendingValidation?.error == nil,
                      pendingValidation?.engine == "volc",
                      !(pendingValidation?.result ?? "").isEmpty else {
                    throw NSError(domain: "Juyi", code: 2)
                }
                let pendingStillMatches = await Task.detached {
                    AppModel.readKeychainCloudCredentials(
                        service: volcPendingKeychainService,
                        account: volcPendingKeychainAccount
                    ) == .found(candidate)
                }.value
                guard pendingStillMatches else { throw NSError(domain: "Juyi", code: 3) }

                // Promotion happens only after the separate pending item has
                // passed a real cloud translation. A failed candidate never
                // overwrites the active credential item.
                activeWriteAttempted = true
                let promoted = await Task.detached {
                    AppModel.saveKeychainCloudCredentials(candidate)
                        && AppModel.readKeychainCloudCredentials() == .found(candidate)
                }.value
                guard promoted else { throw NSError(domain: "Juyi", code: 4) }

                environmentWriteAttempted = true
                try writeEnvironmentWithoutSecrets(engine: "volc")
                guard await startServiceAndWait(expectCloud: true) else {
                    throw NSError(domain: "Juyi", code: 5)
                }
                let validation = await translate("Good tools should feel effortless.", engine: "volc")
                guard validation?.error == nil, validation?.engine == "volc", !(validation?.result ?? "").isEmpty else {
                    throw NSError(domain: "Juyi", code: 7)
                }
                let committedStateMatches = await Task.detached {
                    AppModel.readKeychainCloudCredentials() == .found(candidate)
                        && AppModel.readKeychainCloudCredentials(
                            service: volcPendingKeychainService,
                            account: volcPendingKeychainAccount
                        ) == .found(candidate)
                }.value
                guard committedStateMatches else { throw NSError(domain: "Juyi", code: 8) }
                localCloudCredentialFingerprint = credentialFingerprint(candidate)
                cloudVerified = true
                guard setEngine("volc") else { throw NSError(domain: "Juyi", code: 9) }
                let pendingCleaned = await Task.detached {
                    AppModel.deletePendingCloudCredentials(matching: candidate)
                }.value
                cloudBusy = false
                showCloudSetup = false
                notice = pendingCleaned
                    ? "火山云端已可用。"
                    : "火山云端已可用；安全清理会在下次启动时继续。"
                announce(notice)
                if onboardingPresented && onboardingScreen == .prepare { verifyOnboardingEngine() }
            } catch {
                var keychainRestored = true
                if activeWriteAttempted {
                    keychainRestored = await Task.detached {
                        AppModel.restoreKeychainCloudCredentials(keychainBackup)
                    }.value
                }
                let environmentRestored = !environmentWriteAttempted || restoreEnvironment(environmentBackup)
                var runtimeRestored = true
                if activeWriteAttempted || environmentWriteAttempted {
                    runtimeRestored = await startServiceAndWait()
                }
                var pendingCleaned = !pendingWriteAttempted
                if keychainRestored && environmentRestored && runtimeRestored && pendingWriteAttempted {
                    pendingCleaned = await Task.detached {
                        AppModel.deletePendingCloudCredentials(matching: candidate)
                    }.value
                }
                localCloudCredentialFingerprint = credentialFingerprint(readCloudCredentials())
                if let verifiedFingerprintBackup { UserDefaults.standard.set(verifiedFingerprintBackup, forKey: "cloudVerifiedFingerprint") }
                else { UserDefaults.standard.removeObject(forKey: "cloudVerifiedFingerprint") }
                cloudBusy = false
                if pendingCleaned && keychainRestored && environmentRestored && runtimeRestored {
                    cloudError = "连接验证失败。请确认已经开通机器翻译服务，并检查两项密钥。原来的配置已恢复。"
                } else {
                    cloudError = "连接验证失败，且无法自动恢复原配置。请先不要继续修改，打开“诊断与帮助”。"
                }
                announce(cloudError)
                await refresh()
            }
        }
    }

    private func restoreCloudRemoval(
        activeBackup: CloudCredentialRead,
        pendingBackup: CloudCredentialRead,
        environmentBackup: EnvironmentFileRead,
        selectedEngineBackup: String,
        verifiedFingerprintBackup: String?,
        expectedCloudBackup: Bool
    ) async -> Bool {
        let keychainsRestored = await Task.detached {
            let active = AppModel.restoreKeychainCloudCredentials(activeBackup)
            let pending = AppModel.restoreKeychainCloudCredentials(
                pendingBackup,
                service: volcPendingKeychainService,
                account: volcPendingKeychainAccount
            )
            return active && pending
        }.value
        let environmentRestored = restoreEnvironment(environmentBackup)
        var runtimeRestored = false
        if keychainsRestored && environmentRestored {
            runtimeRestored = await startServiceAndWait(expectCloud: expectedCloudBackup)
        }
        let engineRestored = runtimeRestored && setEngine(selectedEngineBackup)
        if keychainsRestored && environmentRestored && runtimeRestored && engineRestored {
            localCloudCredentialFingerprint = credentialFingerprint(readCloudCredentials())
            if let verifiedFingerprintBackup {
                UserDefaults.standard.set(verifiedFingerprintBackup, forKey: "cloudVerifiedFingerprint")
            } else {
                UserDefaults.standard.removeObject(forKey: "cloudVerifiedFingerprint")
            }
            return true
        }

        // Never leave the shortcut pointing at a cloud engine whose removal or
        // rollback could not be confirmed.
        _ = setEngine("apple")
        localCloudCredentialFingerprint = nil
        UserDefaults.standard.removeObject(forKey: "cloudVerifiedFingerprint")
        return false
    }

    private func startServiceAndWait(expectCloud: Bool? = nil) async -> Bool {
        let domain = "gui/\(getuid())"
        let target = "gui/\(getuid())/\(serviceLabel)"
        let plistPath = plist.path
        let started = await Task.detached {
            if AppModel.launchctl(["print", target]).0 == 0 {
                return AppModel.launchctl(["kickstart", "-k", target]).0 == 0
            }
            return AppModel.launchctl(["bootstrap", domain, plistPath]).0 == 0
        }.value
        guard started else { return false }
        return await waitForService(expectCloud: expectCloud)
    }

    private func stopServiceAndConfirm(allowAlreadyStopped: Bool = false) async -> Bool {
        let target = "gui/\(getuid())/\(serviceLabel)"
        let snapshot = await Task.detached {
            AppModel.launchctl(["print", target])
        }.value
        if snapshot.0 != 0 {
            return allowAlreadyStopped
                && snapshot.1.contains("Could not find service")
        }
        let oldPID = AppModel.launchctlPID(from: snapshot.1)
        let requested = await Task.detached {
            AppModel.launchctl(["bootout", target]).0
        }.value
        // A non-zero result is ambiguous (not loaded, launchctl unavailable,
        // or a real failure). Treat it as failure instead of claiming that
        // credentials were purged from memory.
        guard requested == 0 else { return false }
        var serviceRemoved = false
        for _ in 0..<40 {
            serviceRemoved = await Task.detached {
                let probe = AppModel.launchctl(["print", target])
                return probe.0 != 0 && probe.1.contains("Could not find service")
            }.value
            if serviceRemoved { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard serviceRemoved else { return false }
        guard let oldPID else { return true }
        // launchd may remove the service object before its process finishes
        // the configured 15-second ExitTimeOut. Wait up to 20 seconds for the
        // exact old PID to disappear; PID reuse only causes a safe false failure.
        for _ in 0..<80 {
            let exists = await Task.detached {
                AppModel.processExists(oldPID)
            }.value
            if !exists { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private func completeCloudRemoval(allowAlreadyStopped: Bool) async -> Bool {
        guard await stopServiceAndConfirm(allowAlreadyStopped: allowAlreadyStopped) else {
            return false
        }
        let deleted = await Task.detached {
            let active = AppModel.deleteKeychainCloudCredentials()
            let pending = AppModel.deletePendingCloudCredentials()
            return active && pending
        }.value
        guard deleted else { return false }
        do {
            try writeEnvironmentWithoutSecrets(engine: "apple")
        } catch {
            return false
        }
        guard await startServiceAndWait(expectCloud: false) else {
            _ = await stopServiceAndConfirm(allowAlreadyStopped: true)
            return false
        }
        return true
    }

    private func finishInterruptedCloudRemoval() async -> Bool {
        guard setEngine("apple") else {
            let stopped = await stopServiceAndConfirm(allowAlreadyStopped: true)
            notice = stopped
                ? "无法保存离线翻译方式；后台服务已停止，云端移除会在下次启动时继续。"
                : "无法保存离线翻译方式，也无法确认后台服务已停止；云端请求已被安全阻断。"
            return false
        }
        guard await completeCloudRemoval(allowAlreadyStopped: true) else {
            let stopped = await stopServiceAndConfirm(allowAlreadyStopped: true)
            notice = stopped
                ? "上次的云端移除仍未完成；后台服务保持停止，请打开“诊断与帮助”。"
                : "上次的云端移除仍未完成，且无法确认后台服务已停止；云端请求已被安全阻断。"
            return false
        }
        localCloudCredentialFingerprint = nil
        cloudVerified = false
        showCloudSetup = false
        guard deleteCloudRemovalMarker() else {
            notice = "云端凭据已移除；安全清理会在下次启动时再次确认。"
            return false
        }
        notice = "已完成上次中断的云端移除操作。"
        return true
    }

    func removeCloud() {
        guard !cloudBusy else { return }
        let environmentBackup = readEnvironmentFile()
        guard environmentBackup != .unavailable else {
            cloudError = "暂时无法读取旧的云端设置文件，云端配置未更改。"
            announce(cloudError)
            return
        }
        let keychainBackup = AppModel.readKeychainCloudCredentials()
        guard keychainBackup != .invalid, keychainBackup != .unavailable else {
            cloudError = "暂时无法读取 macOS 钥匙串，云端配置未更改。"
            announce(cloudError)
            return
        }
        let pendingBackup = AppModel.readKeychainCloudCredentials(
            service: volcPendingKeychainService,
            account: volcPendingKeychainAccount
        )
        guard pendingBackup != .invalid, pendingBackup != .unavailable else {
            cloudError = "暂时无法确认待处理的云端设置，云端配置未更改。"
            announce(cloudError)
            return
        }
        let verifiedFingerprintBackup = UserDefaults.standard.string(forKey: "cloudVerifiedFingerprint")
        let selectedEngineBackup = selectedEngine
        let expectedCloudBackup = readCloudCredentials() != nil
        guard createCloudRemovalMarker() else {
            cloudError = "暂时无法创建安全的云端移除事务，原配置未更改。"
            announce(cloudError)
            return
        }
        guard setEngine("apple") else {
            let markerCleared = deleteCloudRemovalMarker()
            cloudError = markerCleared
                ? "暂时无法先切换到离线翻译，云端配置未更改。"
                : "无法切换到离线翻译，安全事务会在下次启动时继续。"
            announce(cloudError)
            return
        }
        cloudBusy = true
        cloudError = ""
        Task {
            let removedFromRuntime = await completeCloudRemoval(allowAlreadyStopped: false)
            if removedFromRuntime {
                localCloudCredentialFingerprint = nil
                cloudVerified = false
                cloudBusy = false
                showCloudSetup = false
                notice = deleteCloudRemovalMarker()
                    ? "已移除火山云端设置，当前只使用离线翻译。"
                    : "云端凭据已移除；安全清理会在下次启动时再次确认。"
                announce(notice)
                return
            }

            let restored = await restoreCloudRemoval(
                activeBackup: keychainBackup,
                pendingBackup: pendingBackup,
                environmentBackup: environmentBackup,
                selectedEngineBackup: selectedEngineBackup,
                verifiedFingerprintBackup: verifiedFingerprintBackup,
                expectedCloudBackup: expectedCloudBackup
            )
            if restored {
                cloudError = deleteCloudRemovalMarker()
                    ? "暂时无法移除云端设置，原配置已完整恢复。"
                    : "原配置已恢复，但安全事务标记未能清理；下次启动会继续处理。"
            } else {
                let stopped = await stopServiceAndConfirm(allowAlreadyStopped: true)
                await refresh()
                cloudError = stopped
                    ? "移除和自动恢复都未完成；后台服务已安全停止，请打开“诊断与帮助”。"
                    : "无法确认云端凭据已从运行内存清除。请退出句译并立即打开“诊断与帮助”。"
            }
            cloudBusy = false
            announce(cloudError)
        }
    }

    func testTranslation() {
        guard !testing, !cloudBusy else { return }; testing = true; testResult = ""; testDetail = "正在测试翻译…"
        let engine = selectedEngine
        Task {
            if engine == "apple" {
                let result = await NativeAppleProductionTranslationService.shared
                    .translate("Good tools should feel effortless.")
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
            let response = await translate("Good tools should feel effortless.", engine: engine)
            testing = false
            if let response, response.error == nil, let result = response.result, !result.isEmpty {
                appleNeedsPreparation = false
                testResult = result
                testDetail = "\(response.engine == "volc" ? "火山云端" : "Apple 离线") · \(response.elapsed_ms ?? 0) ms · 仅确认翻译方式"
                if engine == "volc" { cloudVerified = true }
            } else { testResult = ""; testDetail = friendlyError(response); if response?.error == "apple_error" { appleNeedsPreparation = true }; announce(testDetail) }
        }
    }

    private func translate(_ text: String, engine: String) async -> TranslationResponse? {
        var request = authenticatedRequest(url: serviceURL.appendingPathComponent("translate")); request.httpMethod = "POST"; request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "engine": engine])
        do { let (data, _) = try await URLSession.shared.data(for: request); return try JSONDecoder().decode(TranslationResponse.self, from: data) }
        catch { return nil }
    }
    private func validatePendingCloud() async -> TranslationResponse? {
        var request = authenticatedRequest(url: serviceURL.appendingPathComponent("validate/volc-pending"))
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        do { let (data, _) = try await URLSession.shared.data(for: request); return try JSONDecoder().decode(TranslationResponse.self, from: data) }
        catch { return nil }
    }
    private func waitForService(expectCloud: Bool? = nil) async -> Bool {
        for _ in 0..<16 {
            try? await Task.sleep(for: .milliseconds(400))
            await refresh()
            if serviceReady {
                guard let expectCloud else { return true }
                if cloudConfigured == expectCloud { return true }
            }
        }
        return false
    }
    private func friendlyError(_ response: TranslationResponse?) -> String {
        guard let response else { return "暂时无法连接翻译组件，请检查网络后重试。" }
        switch response.error {
        case "apple_error": return "Apple 离线翻译还没准备好，请下载系统语言包后重试。"
        case "volc_error": return "云端验证失败，请检查访问密钥、网络和机器翻译权限。"
        case "src_lang_mismatch": return "请输入一段英文内容。"
        case "no_engine_available": return "当前没有可用的翻译方式，请先完成引擎设置。"
        default: return "翻译没有完成，请稍后重试。"
        }
    }

    func prepareApple() {
        if selectedEngine == "apple" {
            NativeProductionTranslationCoordinator.shared.prepareLanguages()
            return
        }
        guard !applePreparing else { return }
        guard FileManager.default.fileExists(atPath: helper.path) else { notice = "这台 Mac 暂不支持 Apple 离线翻译，可以改用火山云端。"; return }
        applePreparing = true
        notice = "请在系统窗口中确认下载中英语言包。"
        let path = helper.path
        Task {
            let code = await Task.detached {
                AppModel.runBoundedProcess(
                    executablePath: path,
                    arguments: ["--prepare"],
                    timeout: .seconds(300)
                ).status
            }.value
            applePreparing = false
            appleNeedsPreparation = code != 0
            notice = code == 0
                ? "Apple 离线翻译已准备好。"
                : "语言包还没有准备完成，请重试。"
            announce(notice)
            await refresh()
            if onboardingPresented && onboardingScreen == .prepare {
                verifyOnboardingEngine()
            }
        }
    }

    func openAccessibility() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    func openInstallationGuide() {
        NSWorkspace.shared.open(URL(string: "https://github.com/Eim-aa/juyi#%E5%AE%89%E8%A3%85%E6%89%8B%E5%8A%A8")!)
    }
    func openHammerspoon() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.hammerspoon.Hammerspoon") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
        else { NSWorkspace.shared.open(URL(string: "https://www.hammerspoon.org/")!) }
    }
    func confirmHotkeyWorked() {
        guard NativeProductionTranslationCoordinator.shared.isEnabled else { return }
        onboardingDisposition = .completed
        onboardingPreservesCompletion = true
        onboardingScreen = .complete
        notice = "设置完成。以后选中英文，连按两次 Option 即可。"
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
        let previous = paused
        let native = NativeProductionTranslationCoordinator.shared
        if paused, selectedEngine == "apple", native.resumeAppleRecoveryByUser() {
            onChange?()
            return
        }
        paused = native.recoveryPauseHeld ? true : !paused
        do { try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true); try (paused ? "1\n" : "0\n").write(to: pauseFile, atomically: true, encoding: .utf8) }
        catch { paused = previous; notice = "暂时无法更改状态。"; return }
        native.setPaused(paused, byUser: true)
        #if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB
        if paused != previous {
            NativeOwnerHandoffLabLive.shared.invalidate(.pause)
        }
        #endif
        #if DEBUG && JUYI_NATIVE_SELECTION_CAPTURE_LAB
        if paused != previous {
            NativeSelectionCaptureLabLive.shared.setPaused(paused)
        }
        #endif
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        if paused != previous { NativeTranslationAppleResultLabLive.shared.invalidate(.pause) }
        #elseif DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        if paused != previous { NativeAppleTranslationAdapterCoordinator.shared.invalidate(.pause) }
        #endif
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
        if paused != previous { NativeVolcTranslationAdapterCoordinator.shared.invalidate(.pause) }
        #endif
        onChange?()
    }

    /// A recovery pause uses the same durable switch as the normal Pause
    /// action. Only the native owner may release it, after a fresh HS ack.
    func setLegacyPauseForNativeRecovery(_ pause: Bool) -> Bool {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: pauseFile.path)) == nil else { return false }
        let stored: String?
        do {
            stored = try String(contentsOf: pauseFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch CocoaError.fileReadNoSuchFile {
            stored = nil
        } catch {
            return false
        }
        guard stored == nil || stored == "0" || stored == "1" else { return false }
        if pause {
            guard !paused, stored != "1" else { return false }
        } else {
            guard paused, stored == "1",
                  NativeProductionTranslationCoordinator.shared.recoveryPauseHeld else { return false }
        }
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            try (pause ? "1\n" : "0\n").write(to: pauseFile, atomically: true, encoding: .utf8)
            paused = pause
            onChange?()
            return true
        } catch {
            notice = "无法更新快捷键暂停状态，请检查配置目录后重试。"
            return false
        }
    }

    func pauseForTermination() -> Bool {
        do {
            try "1\n".write(to: pauseFile, atomically: true, encoding: .utf8)
            paused = true
            NativeProductionTranslationCoordinator.shared.setPaused(true, byUser: true)
            return true
        } catch {
            notice = "无法停止快捷键，句译暂未退出。请重试或检查配置目录权限。"
            onChange?()
            return false
        }
    }
    func stopService() {
        guard serviceReady && !serviceBusy && !cloudBusy else { return }; serviceBusy = true
        NativeProductionTranslationCoordinator.shared.invalidate(.stop)
        #if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB
        NativeOwnerHandoffLabLive.shared.invalidate(.stop)
        #endif
        #if DEBUG && JUYI_NATIVE_SELECTION_CAPTURE_LAB
        NativeSelectionCaptureLabLive.shared.invalidate(.stop)
        #endif
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        NativeTranslationAppleResultLabLive.shared.invalidate(.stop)
        #elseif DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        NativeAppleTranslationAdapterCoordinator.shared.invalidate(.stop)
        #endif
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
        NativeVolcTranslationAdapterCoordinator.shared.invalidate(.stop)
        #endif
        Task { _ = await Task.detached { AppModel.launchctl(["bootout", "gui/\(getuid())/\(serviceLabel)"]) }.value; try? await Task.sleep(for: .milliseconds(600)); await refresh(); serviceBusy = false; notice = "后台翻译组件已停止。需要时可点“自动修复”重新启动。" }
    }
    func openLogs() {
        let log = home.appendingPathComponent("Library/Logs/argos-translator.err.log")
        if FileManager.default.fileExists(atPath: log.path) { NSWorkspace.shared.activateFileViewerSelecting([log]) }
    }
    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [.announcement: message])
    }
}

private struct Surface: ViewModifier {
    var selected = false
    func body(content: Content) -> some View {
        content.padding(18).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1))
    }
}

private struct EngineCard: View {
    let symbol: String, title: String, badge: String?, subtitle: String, detail: String, selected: Bool, action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Image(systemName: symbol).font(.title2).foregroundStyle(selected ? Color.accentColor : Color.secondary); Text(title).font(.headline); Spacer(); if let badge { Text(badge).font(.caption).padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule()) }; Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : Color.secondary) }
                Text(subtitle).font(.subheadline).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading).modifier(Surface(selected: selected))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
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
                if let progressText { Text(progressText).font(.callout).foregroundStyle(.secondary).accessibilityLabel(progressAccessibilityLabel) }
            }.padding(.horizontal, 28).padding(.vertical, 18)
            Divider()
            ScrollView {
                Group {
                    switch model.onboardingScreen {
                    case .welcome: welcome
                    case .prepare: prepare
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
        .onChange(of: model.hotkeyProblem) {
            guard model.onboardingScreen == .permission else { return }
            let state = shortcutStatus
            announce("快捷键状态：\(state.title)。\(state.detail)")
            DispatchQueue.main.async { accessibilityFocus = .statusSummary }
        }
        .onChange(of: nativeTranslation.phase) {
            guard model.onboardingScreen == .permission else { return }
            let state = shortcutStatus
            announce("快捷键状态：\(state.title)。\(state.detail)")
            DispatchQueue.main.async { accessibilityFocus = .statusSummary }
        }
    }

    @ViewBuilder private var onboardingFooter: some View {
        switch model.onboardingScreen {
        case .welcome:
            footer(primary: "开始设置", primaryEnabled: true) { model.advanceOnboarding() }
        case .prepare:
            engineFooter
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

    private var progressText: String? {
        switch model.onboardingScreen {
        case .welcome: return "欢迎 · 准备 · 练习 · 完成"
        case .prepare, .permission: return "第 2 步 · 准备"
        case .practice: return "第 3 步 · 练习"
        case .complete: return "第 4 步 · 完成"
        }
    }

    private var progressAccessibilityLabel: String {
        switch model.onboardingScreen {
        case .prepare: return "准备翻译"
        case .permission: return "第 2 步，共 4 步：准备快捷键和翻译"
        case .practice: return "第 3 步，共 4 步：实际试用"
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
            Text("先在文本编辑中试用。其他 App 和文字层 PDF 的支持情况取决于选区接口；扫描件、图片和安全输入框不支持。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 34).padding(.vertical, 24)
    }

    private var prepare: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepTitle("先把翻译准备好", subtitle: model.selectedEngine == "apple" ? "句译优先使用 Apple 离线翻译，文本只在这台 Mac 上处理。" : "继续使用你已经验证过的火山云端翻译设置。")
            engineStatusCard
            if model.onboardingEngineReady {
                VStack(alignment: .leading, spacing: 5) {
                    Text("固定样例自检通过").font(.subheadline.weight(.medium))
                    Text("Good tools should feel effortless. → \(model.onboardingEngineResult)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
            if !model.serviceInstalled {
                Label("句译后台组件尚未安装完整。请打开安装说明并按步骤重新安装；现有设置不会被清除。", systemImage: "shippingbox")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 34).padding(.vertical, 28)
            .onAppear { model.verifyOnboardingEngine() }
    }

    private var engineStatusCard: some View {
        let state = engineStatus
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: state.symbol).font(.title2).foregroundStyle(state.color).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(state.title).font(.headline)
                Text(state.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.onboardingEngineChecking || model.serviceBusy || model.applePreparing { ProgressView().controlSize(.small) }
        }.modifier(Surface())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("翻译状态：\(state.title)。\(state.detail)")
    }

    private var engineStatus: (symbol: String, color: Color, title: String, detail: String) {
        if model.onboardingEngineChecking { return ("hourglass", .secondary, "正在检查翻译组件…", "使用固定英文样例确认当前翻译方式能够工作，不会读取你的内容。") }
        if model.serviceBusy { return ("arrow.triangle.2.circlepath", .secondary, "正在恢复翻译组件…", "句译会自动修复一次，然后继续检查。") }
        if !model.serviceInstalled { return ("shippingbox.fill", Color(nsColor: .systemOrange), "句译安装不完整", "请打开安装说明，并按当前安装步骤重新安装。") }
        if !model.serviceReady { return ("exclamationmark.triangle.fill", Color(nsColor: .systemOrange), "翻译组件没有响应", "自动恢复没有完成，可以重新尝试或查看安装帮助。") }
        if model.selectedEngine == "volc" && (!model.cloudConfigured || !model.cloudVerifiedForUI) { return ("cloud.fill", Color(nsColor: .systemOrange), "需要验证火山云端", "只有你主动配置并验证密钥后，句译才会发送选中的英文。") }
        if model.selectedEngine == "apple" && !model.appleAvailable { return ("desktopcomputer.trianglebadge.exclamationmark", Color(nsColor: .systemOrange), "这台 Mac 无法使用 Apple 离线翻译", "可以主动设置火山云端，句译不会自动上传文字。") }
        if model.appleNeedsPreparation { return ("arrow.down.circle.fill", Color(nsColor: .systemOrange), "还需要下载中英语言包", "macOS 可能显示下载确认。完成后回到句译，这里会自动检查。") }
        if model.onboardingEngineReady { return ("checkmark.circle.fill", Color(nsColor: .systemGreen), model.selectedEngine == "apple" ? "Apple 离线已准备好" : "火山云端已准备好", "已通过固定英文样例自检。") }
        return ("ellipsis.circle.fill", .secondary, "正在准备翻译", "句译会检查当前翻译方式。")
    }

    @ViewBuilder private var engineFooter: some View {
        if model.onboardingEngineReady {
            footer(primary: "继续", primaryEnabled: true) { model.advanceOnboarding() }
        } else if model.appleNeedsPreparation || model.applePreparing {
            footer(primary: model.applePreparing ? "正在准备…" : "下载语言包", primaryEnabled: !model.applePreparing) { model.prepareApple() }
        } else if !model.serviceInstalled {
            footer(primary: "打开安装说明", primaryEnabled: true) { model.openInstallationGuide() }
        } else if model.selectedEngine == "apple" && model.serviceReady && !model.appleAvailable {
            footer(primary: "设置火山云端", primaryEnabled: true) { model.chooseCloud() }
        } else if model.selectedEngine == "volc" && (!model.cloudConfigured || !model.cloudVerifiedForUI) {
            footer(primary: model.cloudConfigured ? "验证云端连接" : "设置火山云端", primaryEnabled: true) { model.chooseCloud() }
        } else {
            footer(primary: (model.onboardingEngineChecking || model.serviceBusy) ? "正在检查…" : "重新尝试", primaryEnabled: !(model.onboardingEngineChecking || model.serviceBusy)) { model.retryOnboardingEngine() }
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepTitle("完成首次准备", subtitle: "允许辅助功能、准备 Apple 语言资源，就能启用双 Option。")
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
                    Text(model.nativeNeedsLegacyHandoff
                        ? "这台 Mac 留有早期快捷键组件，句译需要先安全交接。不会覆盖你的自定义配置；同时请在辅助功能中允许句译。"
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
            if model.nativeNeedsLegacyHandoff {
                preparationRow("处理这台 Mac 上的早期快捷键组件",
                    detail: "仅已有开发组件需要交接；全新安装不需要 Hammerspoon。",
                    complete: model.nativeOwnerBridgeReady || nativeTranslation.isEnabled)
                Divider()
            }
            preparationRow("允许句译使用辅助功能",
                detail: "用于按键监听和读取选区。授权后返回句译，会自动复检。",
                complete: AccessibilityController.status == .authorized)
            Divider()
            preparationRow("Apple 英语 → 简体中文语言资源",
                detail: nativeTranslation.isEnabled ? "已准备好，可在本机翻译。" : "首次准备可能联网，并需要你确认系统下载提示。",
                complete: nativeTranslation.isEnabled)
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
    private var shortcutStatus: (symbol: String, color: Color, title: String, detail: String) {
        if model.userPaused {
            return ("pause.circle.fill", Color(nsColor: .systemOrange), "句译目前已暂停", "恢复句译后即可继续设置或练习双击 Option。")
        }
        if nativeTranslation.isEnabled {
            return ("checkmark.circle.fill", Color(nsColor: .systemGreen), "双 Option 已启用", "现在可以到文本编辑中选中英文，试一次翻译。")
        }
        if model.shortcutRepairBusy {
            return ("arrow.triangle.2.circlepath", .secondary, "正在更新快捷键模块…", "完成重新载入后，句译会继续启用原生双 Option。")
        }
        switch nativeTranslation.phase {
        case .requestingAccessibility:
            return ("hand.raised.fill", .secondary, "正在等待辅助功能权限…", nativeTranslation.detail)
        case .waitingForHammerspoon:
            return ("arrow.left.arrow.right.circle.fill", .secondary, "正在安全交接快捷键…", nativeTranslation.detail)
        case .languagePackRequired:
            return ("arrow.down.circle.fill", Color(nsColor: .systemOrange), nativeTranslation.isPreparingLanguages ? "正在准备 Apple 语言包…" : "需要准备 Apple 语言包", nativeTranslation.detail)
        case .unsupported:
            return ("xmark.circle.fill", Color(nsColor: .systemRed), "这台 Mac 不支持 Apple 离线翻译", nativeTranslation.detail)
        case .unavailable:
            return ("exclamationmark.circle.fill", Color(nsColor: .systemOrange), "原生双 Option 尚未启用", nativeTranslation.detail)
        case .active, .disabled:
            break
        }
        if model.selectedEngine != "apple" {
            return ("lock.shield.fill", Color(nsColor: .systemOrange), "原生双 Option 使用 Apple 离线翻译", "点击下一步会明确切换到 Apple 离线；现有火山云端密钥不会被删除。")
        }
        if !model.nativeNeedsLegacyHandoff || model.nativeOwnerBridgeReady {
            return ("hand.tap.fill", Color(nsColor: .systemOrange), "可以启用双 Option", "点击启用后，按系统提示为句译开启辅助功能权限。")
        }
        switch model.hotkeyProblem {
        case .notInstalled: return ("arrow.down.app.fill", Color(nsColor: .systemOrange), "先安装 Hammerspoon", "此预览版需要这个免费的兼容组件。下载后将它放入应用程序并打开，再回到句译继续。")
        case .notRunning: return ("play.circle.fill", Color(nsColor: .systemOrange), "准备快捷键兼容组件", "句译会打开 Hammerspoon 并更新兼容配置，然后继续启用。")
        case .heartbeatExpired: return ("clock.badge.exclamationmark.fill", Color(nsColor: .systemOrange), "快捷键助手没有响应", "请打开 Hammerspoon，并从它的菜单重新载入配置。")
        case .needsUpdate: return ("arrow.down.circle.fill", Color(nsColor: .systemOrange), "快捷键组件需要更新", "点击继续，句译会自动更新兼容配置。")
        case .notAuthorized: return ("hand.raised.fill", Color(nsColor: .systemOrange), "继续设置双 Option", "句译会先检查兼容组件，再请求自己的辅助功能权限。")
        case .notLoaded: return ("arrow.clockwise.circle.fill", Color(nsColor: .systemOrange), "快捷键配置尚未载入", "请打开 Hammerspoon，并选择 Reload Config。")
        case .paused: return ("pause.circle.fill", Color(nsColor: .systemOrange), "句译目前已暂停", "恢复句译后即可练习双击 Option。")
        case .ready: return ("hand.tap.fill", Color(nsColor: .systemOrange), "可以启用双 Option", "点击启用，让句译准备原生离线翻译。")
        }
    }

    @ViewBuilder private var shortcutFooter: some View {
        if model.userPaused {
            footer(primary: "恢复句译", primaryEnabled: true) { model.togglePause() }
        } else if nativeTranslation.isEnabled {
            footer(primary: "继续", primaryEnabled: true) { model.advanceOnboarding() }
        } else if model.shortcutRepairBusy {
            footer(primary: "正在更新…", primaryEnabled: false) {}
        } else {
            switch nativeTranslation.phase {
            case .requestingAccessibility:
                footer(primary: "打开系统设置", primaryEnabled: true) { model.openAccessibility() }
            case .waitingForHammerspoon:
                footer(primary: nativeTranslation.actionTitle, primaryEnabled: false) {}
            case .languagePackRequired:
                footer(primary: nativeTranslation.isPreparingLanguages ? "正在准备…" : "准备 Apple 语言包", primaryEnabled: !nativeTranslation.isPreparingLanguages) { nativeTranslation.prepareLanguages() }
            case .unsupported:
                footer(primary: "重新检查 Apple 翻译", primaryEnabled: nativeTranslation.actionIsEnabled) { model.enableNativeShortcut() }
            case .unavailable where AccessibilityController.status != .authorized:
                footer(primary: "打开辅助功能设置", primaryEnabled: true) { model.openAccessibility() }
            case .unavailable:
                footer(primary: "重新尝试", primaryEnabled: nativeTranslation.actionIsEnabled) { model.enableNativeShortcut() }
            case .active:
                footer(primary: "继续", primaryEnabled: true) { model.advanceOnboarding() }
            case .disabled:
                if model.selectedEngine != "apple" {
                    footer(primary: "切换到 Apple 离线并启用", primaryEnabled: nativeTranslation.actionIsEnabled) { model.enableNativeShortcut() }
                } else if !model.nativeNeedsLegacyHandoff || model.nativeOwnerBridgeReady || model.hotkeyProblem == .ready {
                    footer(primary: "启用双 Option", primaryEnabled: nativeTranslation.actionIsEnabled) { model.enableNativeShortcut() }
                } else {
                    switch model.hotkeyProblem {
                    case .notInstalled: footer(primary: "前往下载 Hammerspoon", primaryEnabled: true) { model.openHammerspoon() }
                    case .notRunning: footer(primary: "准备并启用双 Option", primaryEnabled: true) { model.enableNativeShortcut() }
                    case .notAuthorized: footer(primary: "继续启用双 Option", primaryEnabled: true) { model.enableNativeShortcut() }
                    case .paused: footer(primary: "恢复句译", primaryEnabled: true) { model.togglePause() }
                    case .heartbeatExpired, .needsUpdate, .notLoaded:
                        footer(primary: "更新并启用双 Option", primaryEnabled: true) { model.enableNativeShortcut() }
                    case .ready:
                        footer(primary: "启用双 Option", primaryEnabled: nativeTranslation.actionIsEnabled) { model.enableNativeShortcut() }
                    }
                }
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
            Text("扫描图片型 PDF 暂不支持。WPS PDF 兼容取词会临时使用剪贴板，剪贴板管理器可能保留原文。")
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
            VStack(alignment: .leading, spacing: 12) {
                Label("关闭窗口：继续在菜单栏运行，仍可翻译。", systemImage: "macwindow")
                Divider()
                Label("暂停翻译：停止响应双 Option，保留设置。", systemImage: "pause.circle")
                Divider()
                Label("退出句译：翻译停止，重开后需手动恢复。", systemImage: "power")
            }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).modifier(Surface())
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
        case .prepare: return "先把翻译准备好"
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
    private func pill(_ text: String) -> some View { Text(text).font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5).background(.quaternary, in: Capsule()) }
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
            HStack { Image(systemName: "cloud.fill").font(.title).foregroundStyle(.blue); VStack(alignment: .leading) { Text("火山翻译配置").font(.title2.bold()); Text("云端翻译目前仅支持火山翻译，需要联网").foregroundStyle(.secondary) } }
            Text("选中的英文会发送至火山翻译。请使用火山的访问密钥，不支持其他服务商的密钥。密钥保存在这台 Mac 的钥匙串中。")
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
            } message: { Text(model.appleAvailable ? "句译将切换到 Apple 离线，选中的文字不再发送到火山翻译。" : "移除后将暂时没有可用的翻译方式。") }
    }
}

private struct DiagnosticsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var nativeTranslation = NativeProductionTranslationCoordinator.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("诊断与帮助").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text("先在文本编辑中选中英文并试用双 Option；这里可以检查权限、语言包和兼容范围。").foregroundStyle(.secondary)
                GroupBox("当前状态") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("双 Option：\(model.hotkeyReady ? "已启用" : "尚未启用")", systemImage: model.hotkeyReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        Text("当前引擎：\(model.selectedEngine == "apple" ? "Apple 离线" : "火山云端")")
                        if model.selectedEngine == "apple" {
                            Text(nativeTranslation.detail).foregroundStyle(.secondary)
                            Text("Apple 翻译直接在本机运行，无需 Python 后台服务。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Label("云端组件：\(model.serviceReady ? "已连接" : "未连接")", systemImage: model.serviceReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                HStack {
                    Button("重新检查") { Task { await model.refresh() } }
                    Button(model.selectedEngine == "apple" ? "重新启用双 Option" : "修复云端组件") { model.repairCurrentTranslation() }
                        .disabled(model.userPaused || model.shortcutRepairBusy || !nativeTranslation.actionIsEnabled)
                    Button("辅助功能设置") { model.openAccessibility() }
                }
                if model.selectedEngine == "apple" {
                    Button(nativeTranslation.isPreparingLanguages ? "正在准备语言包…" : "准备 Apple 语言包") { nativeTranslation.prepareLanguages() }
                        .disabled(model.userPaused || nativeTranslation.isPreparingLanguages)
                }
                if model.selectedEngine == "volc" && !model.serviceInstalled {
                    Label("句译后台组件尚未安装完整。请打开安装说明并按步骤重新安装；现有设置不会被清除。", systemImage: "shippingbox.and.arrow.backward")
                        .foregroundStyle(Color(nsColor: .systemOrange)).fixedSize(horizontal: false, vertical: true)
                    Button("打开安装说明") { model.openInstallationGuide() }
                } else if model.selectedEngine == "volc" && model.serviceReady {
                    Button("停止云端翻译组件", role: .destructive) { model.stopService() }
                }
                DisclosureGroup("支持范围与隐私") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("当前仅支持英语到简体中文。文本编辑和 WPS 文本 PDF 已在本机验证；其他 App 的取词能力取决于其辅助功能接口。扫描图片型 PDF、安全输入框和受保护内容暂不支持。")
                        Text("WPS PDF 兼容取词会临时执行系统复制，并尽力恢复原剪贴板。剪贴板管理器可能保留原文或干扰取词；敏感内容请避免使用这条兼容路径。")
                        Text("本地翻译由句译独立完成，不需要额外安装快捷键工具。检测到已有的早期开发组件时，才会处理兼容交接。Apple 离线失败时不会自动上传云端。")
                        Text("关闭窗口后继续运行；暂停或退出会停止翻译。退出后重新打开，需要点击“恢复句译”。")
                        if model.nativeNeedsLegacyHandoff || model.selectedEngine != "apple" {
                            Button("检查已有 Hammerspoon 组件") { model.openHammerspoon() }
                        }
                        Button("打开技术日志") { model.openLogs() }
                    }.font(.callout).foregroundStyle(.secondary).padding(.top, 6)
                }
                Divider()
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
                        .disabled(model.testing || model.cloudBusy || model.paused || (model.selectedEngine != "apple" && (!model.serviceReady || !model.engineReady)))
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
                HStack { Spacer(); Button("完成") { model.showDiagnostics = false }.keyboardShortcut(.defaultAction) }
            }.padding(28)
        }.frame(width: 500, height: 500)
    }
}

private struct SupportInfoView: View {
    @ObservedObject var model: AppModel
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
                        Text("目前仅支持火山翻译，需联网并配置火山密钥，不支持其他服务商或自定义 API。只有你主动选择并配置云端后，选中的英文才会发送至火山翻译。密钥保存在这台 Mac 的钥匙串中。")
                    }
                    section("后台运行与停止", symbol: "menubar.rectangle") {
                        Text("关闭窗口：句译继续运行。\n暂停翻译：停止翻译，保留设置。\n退出句译：停止翻译；重开后需要点击“恢复翻译”。")
                        Text("Apple 路径的按键监听、取词和翻译由句译独立完成，无需安装 Hammerspoon。已有早期开发组件时，句译会先安全处理快捷键交接。")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("完成") { model.showSupportInfo = false }.keyboardShortcut(.defaultAction) }
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
                    Text(model.selectedEngine == "apple" ? "原生本地翻译" : "云端需另行配置")
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
                if model.selectedEngine == "apple" && nativeTranslation.phase == .disabled
                    && !model.userPaused && !model.translationSetupInProgress {
                    Text("需要句译辅助功能权限和 Apple 中英语言资源；无需另装快捷键工具。")
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
            if !model.ready && model.canPauseTranslation && !model.translationSetupInProgress {
                Text("兼容快捷键可能仍在运行；暂停会同时停止两条翻译路径。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var panelDetail: String {
        if model.userPaused {
            return "现在连按两次 Option 不会翻译。设置仍保留；退出后重新打开，也需要手动恢复。"
        }
        if model.ready { return "" }
        if model.selectedEngine == "apple" && nativeTranslation.phase == .disabled
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
                    Text("目前仅支持火山翻译，需联网并配置后台服务和火山密钥。选中的英文会发送至火山翻译，不支持其他服务商的密钥或自定义 API。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.cloudConfigExists {
                        Button("管理火山翻译配置…") { model.cloudError = ""; model.showCloudSetup = true }
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
    #if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB
    @ObservedObject private var nativeOwnerHandoffLab =
        NativeOwnerHandoffLabLive.shared
    #endif
    #if DEBUG && JUYI_NATIVE_SELECTION_CAPTURE_LAB
    @ObservedObject private var nativeSelectionCaptureLab =
        NativeSelectionCaptureLabLive.shared
    #endif
    #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
    @ObservedObject private var nativeAppleTranslationAdapter =
        NativeAppleTranslationAdapterCoordinator.shared
    #endif
    #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
    @ObservedObject private var nativeVolcTranslationAdapter =
        NativeVolcTranslationAdapterCoordinator.shared
    #endif
    #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
    @ObservedObject private var nativeTranslationResultLab =
        NativeTranslationResultLabLive.shared
    #endif
    #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
    @ObservedObject private var nativeAppleResultLab =
        NativeTranslationAppleResultLabLive.shared
    #endif
    var body: some View {
        Group {
            if model.onboardingPresented { OnboardingView(model: model) }
            else { AppView(model: model) }
        }
        .sheet(isPresented: $model.showCloudSetup) { CloudSetupView(model: model) }
        .sheet(isPresented: $model.showDiagnostics) { DiagnosticsView(model: model) }
        .sheet(isPresented: $model.showSupportInfo) { SupportInfoView(model: model) }
        .background(
            NativeAppleProductionTranslationHost(
                service: NativeAppleProductionTranslationService.shared
            )
        )
        #if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB
        .sheet(
            isPresented: Binding(
                get: { nativeOwnerHandoffLab.isPresented },
                set: { presented in
                    if !presented { nativeOwnerHandoffLab.close() }
                }
            )
        ) {
            NativeOwnerHandoffLabHost()
        }
        #endif
        #if DEBUG && JUYI_NATIVE_SELECTION_CAPTURE_LAB
        .sheet(
            isPresented: Binding(
                get: { nativeSelectionCaptureLab.isPresented },
                set: { presented in
                    if !presented { nativeSelectionCaptureLab.close() }
                }
            )
        ) {
            NativeSelectionCaptureLabHost()
        }
        #endif
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        .sheet(
            isPresented: Binding(
                get: { nativeAppleTranslationAdapter.isPresented },
                set: { presented in
                    if !presented { nativeAppleTranslationAdapter.close() }
                }
            )
        ) {
            NativeAppleTranslationAdapterSheet(
                coordinator: nativeAppleTranslationAdapter
            )
        }
        #endif
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
        .sheet(
            isPresented: Binding(
                get: { nativeVolcTranslationAdapter.isPresented },
                set: { presented in
                    if !presented { nativeVolcTranslationAdapter.close() }
                }
            )
        ) {
            NativeVolcTranslationAdapterSheet(coordinator: nativeVolcTranslationAdapter)
        }
        #endif
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        .sheet(
            isPresented: Binding(
                get: { nativeTranslationResultLab.isPresented },
                set: { presented in
                    if !presented { nativeTranslationResultLab.close() }
                }
            )
        ) {
            NativeTranslationResultLabSheet(coordinator: nativeTranslationResultLab)
        }
        #endif
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        .sheet(
            isPresented: Binding(
                get: { nativeAppleResultLab.isPresented },
                set: { presented in
                    if !presented { nativeAppleResultLab.close() }
                }
            )
        ) {
            NativeTranslationAppleResultLabSheet(coordinator: nativeAppleResultLab)
        }
        #endif
    }
}

private extension AppModel {
    var cloudVerifiedForUI: Bool { cloudVerified }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var window: NSWindow!
    private var lastOnboardingMode: Bool?
    private var nativeTranslationObservation: AnyCancellable?
    private var nativeProductionIsAwake = true
    private var nativeProductionSessionIsActive = true
    #if DEBUG && JUYI_NATIVE_TRANSLATION_OVERLAY && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
    private var nativeOverlayPreviewMenuItem: NSMenuItem?
    #endif
    #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
    private var nativeAppleResultLabAccessibilityStatus = AccessibilityController.status
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isLoginLaunch = launchedFromLogin
        NativeProductionTranslationCoordinator.shared.legacyRecoveryPauseHandler = {
            [weak self] pause in self?.model.setLegacyPauseForNativeRecovery(pause) ?? false
        }
        NSApp.setActivationPolicy(.regular); installMainMenu(); createWindow()
        model.onChange = { [weak self] in self?.updateChrome() }; updateChrome()
        NativeTranslationOverlayController.shared.configureNavigation {
            [weak self] cta in self?.handleNativeOverlayCTA(cta)
        }
        NativeTranslationOverlayController.shared.setPaused(model.paused)
        nativeTranslationObservation = NativeProductionTranslationCoordinator.shared
            .objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateChrome() }
            }
        NativeProductionTranslationCoordinator.shared.setPaused(model.paused)
        NativeProductionTranslationCoordinator.shared
            .setAppleEngineSelected(model.selectedEngine == "apple")
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
        #if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self, selector: #selector(nativeOwnerHandoffWillSleep(_:)),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        workspaceCenter.addObserver(
            self, selector: #selector(nativeOwnerHandoffSessionResigned(_:)),
            name: NSWorkspace.sessionDidResignActiveNotification, object: nil
        )
        #elseif DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self, selector: #selector(nativeAppleResultLabWillSleep(_:)),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        workspaceCenter.addObserver(
            self, selector: #selector(nativeAppleResultLabSessionResigned(_:)),
            name: NSWorkspace.sessionDidResignActiveNotification, object: nil
        )
        workspaceCenter.addObserver(
            self, selector: #selector(nativeAppleResultLabSpaceChanged(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(nativeAppleResultLabDisplayChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        #elseif DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self, selector: #selector(nativeVolcWillSleep(_:)),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        workspaceCenter.addObserver(
            self, selector: #selector(nativeVolcDidWake(_:)),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        workspaceCenter.addObserver(
            self, selector: #selector(nativeVolcSessionResigned(_:)),
            name: NSWorkspace.sessionDidResignActiveNotification, object: nil
        )
        #endif
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
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        let currentAccessibilityStatus = AccessibilityController.status
        if nativeAppleResultLabAccessibilityStatus == .authorized,
           currentAccessibilityStatus == .notAuthorized {
            NativeTranslationAppleResultLabLive.shared.invalidate(.accessibilityRevoked)
        }
        nativeAppleResultLabAccessibilityStatus = currentAccessibilityStatus
        #endif
    }
    func applicationWillTerminate(_ notification: Notification) {
        NativeProductionTranslationCoordinator.shared.invalidate(.terminate)
        #if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NativeOwnerHandoffLabLive.shared.invalidate(.terminate)
        #endif
        #if DEBUG && JUYI_NATIVE_SELECTION_CAPTURE_LAB
        NativeSelectionCaptureLabLive.shared.invalidate(.terminate)
        #endif
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NativeTranslationAppleResultLabLive.shared.invalidate(.ownerChanged)
        #elseif DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        NativeTranslationResultLabLive.shared.invalidate(.ownerChanged)
        #endif
        NativeTranslationOverlayController.shared.shutdown()
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        NativeAppleTranslationAdapterCoordinator.shared.invalidate(.terminate)
        #endif
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NativeVolcTranslationAdapterCoordinator.shared.invalidate(.terminate)
        #endif
        if model.onboardingPresented { model.deferOnboarding() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Pause the shared legacy path before releasing the native owner lease.
        // Closing a window does not enter this path; quitting stops translation.
        guard model.pauseForTermination() else {
            showWindow()
            return .terminateCancel
        }
        return .terminateNow
    }
    func windowWillClose(_ notification: Notification) {
        #if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB
        NativeOwnerHandoffLabLive.shared.close()
        #endif
        #if DEBUG && JUYI_NATIVE_SELECTION_CAPTURE_LAB
        NativeSelectionCaptureLabLive.shared.close()
        #endif
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        NativeTranslationAppleResultLabLive.shared.close()
        #elseif DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        NativeTranslationResultLabLive.shared.close()
        #endif
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        NativeAppleTranslationAdapterCoordinator.shared.close()
        #endif
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
        NativeVolcTranslationAdapterCoordinator.shared.close()
        #endif
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
        #if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB
        let ownerLab = NSMenuItem(
            title: "开发：双 Option owner 交接实验室…",
            action: #selector(openNativeOwnerHandoffLab),
            keyEquivalent: ""
        )
        ownerLab.target = self
        submenu.addItem(ownerLab)
        submenu.addItem(.separator())
        #elseif DEBUG && JUYI_NATIVE_SELECTION_CAPTURE_LAB
        let captureLab = NSMenuItem(
            title: "开发：原生取词实验室…",
            action: #selector(openNativeSelectionCaptureLab),
            keyEquivalent: ""
        )
        captureLab.target = self
        submenu.addItem(captureLab)
        submenu.addItem(.separator())
        #elseif DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        let resultLab = NSMenuItem(
            title: "开发：真实 Apple 结果实验室…",
            action: #selector(openNativeAppleResultLab),
            keyEquivalent: ""
        )
        resultLab.target = self
        submenu.addItem(resultLab)
        let focusResult = NSMenuItem(
            title: "聚焦当前结果",
            action: #selector(focusNativeAppleResultLab),
            keyEquivalent: ""
        )
        focusResult.target = self
        submenu.addItem(focusResult)
        submenu.addItem(.separator())
        #elseif DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        let resultLab = NSMenuItem(
            title: "开发：结果界面实验室…",
            action: #selector(openNativeTranslationResultLab),
            keyEquivalent: ""
        )
        resultLab.target = self
        submenu.addItem(resultLab)
        let focusResult = NSMenuItem(
            title: "聚焦当前结果",
            action: #selector(focusNativeTranslationResultLab),
            keyEquivalent: ""
        )
        focusResult.target = self
        submenu.addItem(focusResult)
        submenu.addItem(.separator())
        #elseif DEBUG && JUYI_NATIVE_TRANSLATION_OVERLAY
        let preview = NSMenuItem(title: NativeTranslationOverlayController.shared.nextFixturePreviewTitle, action: #selector(previewNativeOverlay), keyEquivalent: ""); preview.target = self; nativeOverlayPreviewMenuItem = preview; submenu.addItem(preview)
        let focus = NSMenuItem(title: "聚焦当前译文", action: #selector(focusNativeOverlay), keyEquivalent: ""); focus.target = self; submenu.addItem(focus)
        submenu.addItem(.separator())
        #endif
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        let appleAdapter = NSMenuItem(
            title: "开发：测试 Apple 离线翻译…",
            action: #selector(testNativeAppleTranslationAdapter),
            keyEquivalent: ""
        )
        appleAdapter.target = self
        submenu.addItem(appleAdapter)
        submenu.addItem(.separator())
        #endif
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
        let volcAdapter = NSMenuItem(
            title: "开发：测试火山云端翻译…",
            action: #selector(testNativeVolcTranslationAdapter),
            keyEquivalent: ""
        )
        volcAdapter.target = self
        submenu.addItem(volcAdapter)
        submenu.addItem(.separator())
        #endif
        let quit = NSMenuItem(title: "退出句译", action: #selector(terminate), keyEquivalent: "q"); quit.target = self; submenu.addItem(quit)
        app.submenu = submenu; main.addItem(app); NSApp.mainMenu = main
    }
    private func item(_ title: String, action: Selector? = nil, enabled: Bool = true) -> NSMenuItem { let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self; i.isEnabled = enabled; return i }
    private func updateMenu() {
        let symbol = model.ready ? "character.bubble.fill" : model.summarySymbol
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "句译 · \(model.summaryStatus)")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "句译 · \(model.summaryStatus)"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("句译 · \(model.summaryStatus)", enabled: false))
        menu.addItem(item(model.primaryActionTitle, action: #selector(primaryAction), enabled: model.primaryActionEnabled))
        if !model.ready && model.canPauseTranslation {
            menu.addItem(item("暂停所有翻译", action: #selector(pause)))
        }
        menu.addItem(.separator())
        menu.addItem(item("打开句译…", action: #selector(showWindow)))
        let engine = item("翻译方式")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let apple = item("本地翻译（Apple）", action: #selector(apple))
        apple.state = model.selectedEngine == "apple" ? .on : .off
        let cloud = item("云端翻译（仅火山）…", action: #selector(cloud))
        cloud.state = model.selectedEngine == "volc" ? .on : .off
        sub.addItem(apple); sub.addItem(cloud); engine.submenu = sub
        engine.isEnabled = !model.translationSetupInProgress && !model.cloudBusy
        menu.addItem(engine)
        menu.addItem(item(model.onboardingCompleted ? "重新练习双 Option…" : "继续设置…", action: #selector(onboarding)))
        menu.addItem(item("支持范围与隐私…", action: #selector(supportInfo)))
        menu.addItem(item("诊断与帮助…", action: #selector(diagnostics)))
        menu.addItem(.separator())
        let quit = item("退出句译", action: #selector(terminate))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        statusItem.menu = menu
    }
    private func updateChrome() {
        #if DEBUG && JUYI_NATIVE_SELECTION_CAPTURE_LAB
        NativeSelectionCaptureLabLive.shared.setPaused(model.paused)
        #endif
        NativeTranslationOverlayController.shared.setPaused(model.userPaused)
        updateMenu()
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
    #if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB
    @objc private func openNativeOwnerHandoffLab() {
        showWindow()
        NativeOwnerHandoffLabLive.shared.open()
    }
    #endif
    #if DEBUG && JUYI_NATIVE_SELECTION_CAPTURE_LAB
    @objc private func openNativeSelectionCaptureLab() {
        showWindow()
        NativeSelectionCaptureLabLive.shared.setPaused(model.paused)
        NativeSelectionCaptureLabLive.shared.open()
    }
    #endif
    @objc private func onboarding() {
        if model.onboardingCompleted {
            model.hotkeyReady ? model.relearnShortcut() : model.repairShortcut()
        } else {
            model.startOnboarding()
        }
        showWindow()
    }
    #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
    @objc private func openNativeAppleResultLab() {
        showWindow()
        NativeTranslationAppleResultLabLive.shared.open()
    }
    @objc private func focusNativeAppleResultLab() {
        NativeTranslationAppleResultLabLive.shared.focusCurrentResult()
    }
    #elseif DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
    @objc private func openNativeTranslationResultLab() {
        showWindow()
        NativeTranslationResultLabLive.shared.open()
    }
    @objc private func focusNativeTranslationResultLab() {
        NativeTranslationResultLabLive.shared.focusCurrentResult()
    }
    #endif

    #if DEBUG && JUYI_NATIVE_TRANSLATION_OVERLAY && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
    @objc private func previewNativeOverlay() {
        NativeTranslationOverlayController.shared.showFixturePreview()
        nativeOverlayPreviewMenuItem?.title = NativeTranslationOverlayController.shared
            .nextFixturePreviewTitle
    }
    @objc private func focusNativeOverlay() {
        NativeTranslationOverlayController.shared.focusCurrentOverlay()
    }
    #endif
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
            model.cloudError = ""
            model.showCloudSetup = true
            showWindow()
        case .chooseEngine:
            showWindow()
        }
    }
    #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
    @objc private func testNativeAppleTranslationAdapter() {
        showWindow()
        NativeAppleTranslationAdapterCoordinator.shared.open()
    }
    #endif
    #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
    @objc private func testNativeVolcTranslationAdapter() {
        showWindow()
        NativeVolcTranslationAdapterCoordinator.shared.open()
    }
    @objc private func nativeVolcWillSleep(_ notification: Notification) {
        NativeVolcTranslationAdapterCoordinator.shared.invalidate(.sleep)
    }
    @objc private func nativeVolcDidWake(_ notification: Notification) {
        NativeVolcTranslationAdapterCoordinator.shared.invalidate(.wake)
    }
    @objc private func nativeVolcSessionResigned(_ notification: Notification) {
        NativeVolcTranslationAdapterCoordinator.shared.invalidate(.sessionResigned)
    }
    #endif
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
    #if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB
    @objc private func nativeOwnerHandoffWillSleep(_ notification: Notification) {
        NativeOwnerHandoffLabLive.shared.invalidate(.sleep)
    }
    @objc private func nativeOwnerHandoffSessionResigned(_ notification: Notification) {
        NativeOwnerHandoffLabLive.shared.invalidate(.sessionResigned)
    }
    #endif
    #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
    @objc private func nativeAppleResultLabWillSleep(_ notification: Notification) {
        NativeTranslationAppleResultLabLive.shared.invalidate(.ownerChanged)
    }
    @objc private func nativeAppleResultLabSessionResigned(_ notification: Notification) {
        NativeTranslationAppleResultLabLive.shared.invalidate(.ownerChanged)
    }
    @objc private func nativeAppleResultLabSpaceChanged(_ notification: Notification) {
        NativeTranslationAppleResultLabLive.shared.invalidate(.ownerChanged)
    }
    @objc private func nativeAppleResultLabDisplayChanged(_ notification: Notification) {
        NativeTranslationAppleResultLabLive.shared.invalidate(.ownerChanged)
    }
    #endif
    @objc private func apple() {
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        NativeTranslationAppleResultLabLive.shared.invalidate(.engineChanged)
        #elseif DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        NativeTranslationResultLabLive.shared.invalidate(.engineChanged)
        #endif
        model.chooseApple()
    }
    @objc private func cloud() {
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        NativeTranslationAppleResultLabLive.shared.invalidate(.engineChanged)
        #elseif DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        NativeTranslationResultLabLive.shared.invalidate(.engineChanged)
        #endif
        model.chooseCloud(); showWindow()
    }
    @objc private func primaryAction() {
        model.performPrimaryAction()
        if !model.ready && !model.userPaused { showWindow() }
    }
    @objc private func supportInfo() { model.showSupportInfo = true; showWindow() }
    @objc private func pause() { model.togglePause() }; @objc private func diagnostics() { model.showDiagnostics = true; showWindow() }; @objc private func terminate() { NSApp.terminate(nil) }
}

#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(focusNativeAppleResultLab) {
            return NativeTranslationAppleResultLabLive.shared.hasVisibleResult
        }
        return true
    }
}
#elseif DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(focusNativeTranslationResultLab) {
            return NativeTranslationResultLabMenuPolicy.focusIsEnabled(
                hasVisibleResult: NativeTranslationResultLabLive.shared.hasVisibleResult
            )
        }
        return true
    }
}
#endif

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
