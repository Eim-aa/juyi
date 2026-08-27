import AppKit
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
}

private struct TranslationResponse: Decodable {
    let result: String?
    let engine: String?
    let elapsed_ms: Int?
    let error: String?
    let warnings: [String]?
}

enum HotkeyProblem: Equatable {
    case notInstalled, notRunning, heartbeatExpired, notAuthorized, notLoaded, paused, ready
}

enum LoginItemState: Equatable {
    case enabled, notRegistered, requiresApproval, notFound
}

private enum LoginItemBackend {
    case serviceManagement, launchAgent
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

    var onChange: (() -> Void)?
    private var timer: Timer?
    private var onboardingPreservesCompletion = false
    private var autoRepairAttempted = false
    private var loginItemMigrationInProgress = false
    private var loginItemBackend: LoginItemBackend = .serviceManagement
    private var localCloudCredentialFingerprint: String?
    private let loginItemRegistrationKey = "loginItemInitialRegistrationAttempted"
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var configDir: URL { home.appendingPathComponent(".config/argos-translator") }
    private var engineFile: URL { configDir.appendingPathComponent("hs-engine") }
    private var pauseFile: URL { configDir.appendingPathComponent("hs-paused") }
    private var hotkeyFile: URL { configDir.appendingPathComponent("hs-status.json") }
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
        // A persisted removal transaction takes precedence over legacy
        // migration; never recreate an active credential while removal is
        // waiting to finish.
        if readCloudRemovalMarker() == .notFound {
            migrateLegacyCloudCredentialsIfNeeded()
        }
        localCloudCredentialFingerprint = credentialFingerprint(readCloudCredentials())
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
            onboardingScreen = .prepare; onboardingPresented = true
        case .deferred, .completed:
            onboardingPresented = false
        }
        configureDefaultLoginItemIfNeeded()
        // Hold the cloud-operation lock before the first scheduled task can
        // yield, so the setup UI cannot race crash recovery during launch.
        cloudBusy = true
        Task {
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
    }

    var hammerspoonInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.hammerspoon.Hammerspoon") != nil
    }
    var hammerspoonRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "org.hammerspoon.Hammerspoon").isEmpty
    }
    var serviceReady: Bool { health?.ok == true }
    var serviceInstalled: Bool { FileManager.default.fileExists(atPath: plist.path) }
    var appleHelperInstalled: Bool { FileManager.default.fileExists(atPath: helper.path) }
    var appleAvailable: Bool { health?.engines["apple"] == true }
    var cloudConfigured: Bool { health?.engines["volc"] == true }
    var cloudConfigExists: Bool { localCloudCredentialFingerprint != nil }
    var hotkeyReady: Bool {
        hotkeyProblem == .ready
    }
    var hotkeyProblem: HotkeyProblem {
        if !hammerspoonInstalled { return .notInstalled }
        if !hammerspoonRunning { return .notRunning }
        guard let hotkey, let updated = hotkey.updated_at,
              Date().timeIntervalSince1970 - updated < 6 else { return .heartbeatExpired }
        if hotkey.accessibility != true { return .notAuthorized }
        if paused || hotkey.paused == true { return .paused }
        if hotkey.module_loaded != true || hotkey.watcher_active != true { return .notLoaded }
        return .ready
    }
    var engineReady: Bool { selectedEngine == "apple" ? appleAvailable : (cloudConfigured && cloudVerified) }
    var onboardingCompleted: Bool { onboardingDisposition == .completed }
    var ready: Bool { !paused && serviceReady && hotkeyReady && engineReady && onboardingCompleted }
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
        if paused { return "句译已暂停" }
        if ready { return "句译已就绪" }
        if !serviceReady { return "句译需要处理" }
        return "还差一步"
    }
    var statusMessage: String {
        if !hasChecked { return "这通常只需要几秒。" }
        if paused { return "恢复后即可继续使用双击 Option 翻译。" }
        if !serviceReady { return serviceBusy ? "正在重新连接翻译组件…" : "翻译组件暂时没有响应，可以自动修复。" }
        if !engineReady { return selectedEngine == "volc" ? "验证云端连接后即可开始使用。" : "需要准备 Apple 离线翻译。" }
        switch hotkeyProblem {
        case .notInstalled: return "需要先安装 Hammerspoon 快捷键助手。"
        case .notRunning: return "Hammerspoon 尚未运行，请打开它。"
        case .heartbeatExpired: return "快捷键助手没有响应，请重新打开 Hammerspoon。"
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
        if paused { return "pause.circle.fill" }
        if ready { return "checkmark.circle.fill" }
        return serviceReady ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill"
    }
    var statusColor: Color {
        if !hasChecked { return .secondary }
        if paused { return .secondary }
        if ready { return Color(nsColor: .systemGreen) }
        return serviceReady ? Color(nsColor: .systemOrange) : Color(nsColor: .systemRed)
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
        onboardingScreen = .prepare
        onboardingPresented = true
        verifyOnboardingEngine()
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
            guard hotkeyReady else { return }
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
        OnboardingPolicy.firstIncompleteScreen(
            serviceReady: serviceReady,
            engineReady: engineReady,
            hotkeyReady: hotkeyReady
        )
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
        onChange?()
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
        if let value = readExplicitEngineChoice() {
            selectedEngine = value
        }
        paused = ((try? String(contentsOf: pauseFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        if let data = try? Data(contentsOf: hotkeyFile), let decoded = try? JSONDecoder().decode(HotkeyStatus.self, from: data) { hotkey = decoded }
        else { hotkey = nil }
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

    private func migrateLegacyCloudCredentialsIfNeeded() {
        guard let legacy = readLegacyCloudCredentials() else { return }
        guard case .found(let oldEnvironment) = readEnvironmentFile() else { return }
        let oldEnvironmentFingerprint = SHA256.hash(data: oldEnvironment).map { String(format: "%02x", $0) }.joined()
        let legacyWasVerified = oldEnvironmentFingerprint == UserDefaults.standard.string(forKey: "cloudVerifiedFingerprint")
        let keychainState = AppModel.readKeychainCloudCredentials()
        let activeCredentials: CloudCredentials
        switch keychainState {
        case .found(let credentials):
            activeCredentials = credentials
        case .notFound:
            guard AppModel.saveKeychainCloudCredentials(legacy),
                  AppModel.readKeychainCloudCredentials() == .found(legacy) else { return }
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

    nonisolated private static func launchctl(_ args: [String]) -> (Int32, String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = args
        process.standardOutput = pipe; process.standardError = pipe
        do {
            try process.run(); process.waitUntilExit()
            return (process.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        } catch { return (1, error.localizedDescription) }
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
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let inputPipe = input == nil ? nil : Pipe()
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        do {
            try process.run()
            if let input, let inputPipe {
                inputPipe.fileHandleForWriting.write(input)
                inputPipe.fileHandleForWriting.closeFile()
            }
            process.waitUntilExit()
            return (process.terminationStatus, output.fileHandleForReading.readDataToEndOfFile())
        } catch {
            inputPipe?.fileHandleForWriting.closeFile()
            return (1, Data())
        }
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
        guard serviceReady else { notice = "请先恢复翻译组件，再选择翻译方式。"; repairService(); return }
        if appleAvailable {
            if setEngine("apple") { notice = "已切换到 Apple 离线翻译。" }
        }
        else { notice = "这台 Mac 还没有准备好离线翻译。"; prepareApple() }
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
            selectedEngine = engine; onChange?()
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
        guard !applePreparing else { return }
        guard FileManager.default.fileExists(atPath: helper.path) else { notice = "这台 Mac 暂不支持 Apple 离线翻译，可以改用火山云端。"; return }
        applePreparing = true
        notice = "请在系统窗口中确认下载中英语言包。"
        let path = helper.path
        Task { let code = await Task.detached { () -> Int32 in let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = ["--prepare"]; try? p.run(); p.waitUntilExit(); return p.terminationStatus }.value; applePreparing = false; appleNeedsPreparation = code != 0; notice = code == 0 ? "Apple 离线翻译已准备好。" : "语言包还没有准备完成，请重试。"; announce(notice); await refresh(); if onboardingPresented && onboardingScreen == .prepare { verifyOnboardingEngine() } }
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
        guard hotkeyReady else { return }
        onboardingDisposition = .completed
        onboardingPreservesCompletion = true
        onboardingScreen = .complete
        notice = "设置完成。以后选中英文，连按两次 Option 即可。"
        announce("句译准备好了")
        onChange?()
    }
    func togglePause() {
        paused.toggle()
        do { try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true); try (paused ? "1\n" : "0\n").write(to: pauseFile, atomically: true, encoding: .utf8) }
        catch { paused.toggle(); notice = "暂时无法更改状态。" }
        onChange?()
    }
    func stopService() {
        guard serviceReady && !serviceBusy && !cloudBusy else { return }; serviceBusy = true
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

/// AppKit text view is intentional: unlike a SwiftUI Text label it supports
/// real mouse, keyboard and VoiceOver selection for the end-to-end hotkey test.
private struct SelectablePracticeText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        let textView = NSTextView()
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 16, weight: .medium)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("练习文本：Good tools should feel effortless。请选择这段文字，然后连按两次 Option。")
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text { textView.string = text }
        textView.textColor = .labelColor
    }
}

private enum OnboardingAccessibilityFocus: Hashable {
    case pageTitle, statusSummary
}

private struct OnboardingView: View {
    @ObservedObject var model: AppModel
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
                .id(model.onboardingScreen)
                .transition(.opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: model.onboardingScreen)
            }
            Divider()
            onboardingFooter.padding(.horizontal, 34).padding(.vertical, 16)
        }
        .frame(minWidth: 580, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focusAndAnnouncePage() }
        .onChange(of: model.onboardingScreen) { focusAndAnnouncePage() }
        .onChange(of: model.hotkeyProblem) {
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
                Button("我看到了译文") { model.confirmHotkeyWorked() }
                    .keyboardShortcut(.defaultAction).disabled(!model.hotkeyReady)
            }
        case .complete:
            HStack { Spacer(); Button("开始使用") { model.finishOnboarding() }.keyboardShortcut(.defaultAction) }
        }
    }

    private var progressText: String? {
        switch model.onboardingScreen {
        case .prepare: return "步骤 1，共 3 步"
        case .permission: return "步骤 2，共 3 步"
        case .practice: return "步骤 3，共 3 步"
        case .welcome, .complete: return nil
        }
    }

    private var progressAccessibilityLabel: String {
        switch model.onboardingScreen {
        case .prepare: return "步骤 1，共 3 步：准备翻译"
        case .permission: return "步骤 2，共 3 步：允许快捷键"
        case .practice: return "步骤 3，共 3 步：实际试用"
        case .welcome, .complete: return ""
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(spacing: 8) {
                Text("欢迎使用句译").font(.system(size: 28, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($accessibilityFocus, equals: .pageTitle)
                Text("选中英文，连按两次 Option，中文译文就会出现在旁边。")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 16) {
                welcomeAction("选中英文", symbol: "selection.pin.in.out")
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                HStack(spacing: 4) { keycap("⌥"); keycap("⌥") }
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                welcomeAction("查看中文", symbol: "character.bubble")
            }.accessibilityElement(children: .combine).accessibilityLabel("选中英文，然后连按两次 Option，查看中文")
            HStack(spacing: 10) { pill("默认离线"); pill("支持多数可选文本 App"); pill("Dock 与菜单栏") }
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
            stepTitle("允许句译响应快捷键", subtitle: "句译通过 Hammerspoon 读取你主动选中的文字，并响应双击 Option。")
            DisclosureGroup("这项权限有什么作用？", isExpanded: $showPermissionExplanation) {
                Text("macOS 将它归入“辅助功能”权限。句译只在你触发翻译时读取选中的文字；你可以随时在系统设置中关闭权限。")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            }
            shortcutStatusCard
            if model.hotkeyProblem != .ready {
                HStack(spacing: 12) {
                    Button("重新检查") { Task { await model.refresh() } }
                    Button("仍然无法完成…") { model.permissionTroubleshooting.toggle() }.buttonStyle(.link)
                }
            }
            if model.permissionTroubleshooting {
                VStack(alignment: .leading, spacing: 6) {
                    Text("仍然无法完成？").font(.subheadline.weight(.medium))
                    Text("确认 Hammerspoon 已打开；在辅助功能中关闭再打开它的开关；然后从 Hammerspoon 菜单选择 Reload Config。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("打开诊断") { model.showDiagnostics = true }.buttonStyle(.link)
                }
            }
        }.padding(.horizontal, 34).padding(.vertical, 28)
    }

    private var shortcutStatusCard: some View {
        let state = shortcutStatus
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: state.symbol).font(.title2).foregroundStyle(state.color).frame(width: 28)
                VStack(alignment: .leading, spacing: 5) { Text(state.title).font(.headline); Text(state.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Spacer()
            }
            if model.hotkeyProblem == .notAuthorized {
                VStack(alignment: .leading, spacing: 4) {
                    Text("辅助功能").fontWeight(.medium)
                    Text("请在列表中找到 Hammerspoon，并打开它右侧的系统开关。").foregroundStyle(.secondary)
                }
                .padding(10).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            }
        }.modifier(Surface()).accessibilityElement(children: .combine)
            .accessibilityLabel("快捷键状态：\(state.title)。\(state.detail)")
            .accessibilityFocused($accessibilityFocus, equals: .statusSummary)
    }

    private var shortcutStatus: (symbol: String, color: Color, title: String, detail: String) {
        switch model.hotkeyProblem {
        case .notInstalled: return ("arrow.down.app.fill", Color(nsColor: .systemOrange), "需要安装一次快捷键助手", "安装完成后回到句译，这里会自动继续。")
        case .notRunning: return ("play.circle.fill", Color(nsColor: .systemOrange), "打开 Hammerspoon", "它会在后台响应双击 Option。")
        case .heartbeatExpired: return ("clock.badge.exclamationmark.fill", Color(nsColor: .systemOrange), "快捷键助手没有响应", "请打开 Hammerspoon，并从它的菜单重新载入配置。")
        case .notAuthorized: return ("hand.raised.fill", Color(nsColor: .systemOrange), "还没有检测到权限", "请在“系统设置 → 隐私与安全性 → 辅助功能”中打开 Hammerspoon。")
        case .notLoaded: return ("arrow.clockwise.circle.fill", Color(nsColor: .systemOrange), "快捷键配置尚未载入", "请打开 Hammerspoon，并选择 Reload Config。")
        case .paused: return ("pause.circle.fill", Color(nsColor: .systemOrange), "句译目前已暂停", "恢复句译后即可练习双击 Option。")
        case .ready: return ("checkmark.circle.fill", Color(nsColor: .systemGreen), "快捷键权限已开启", "Hammerspoon 正在响应双击 Option。")
        }
    }

    @ViewBuilder private var shortcutFooter: some View {
        switch model.hotkeyProblem {
        case .ready: footer(primary: "继续", primaryEnabled: true) { model.advanceOnboarding() }
        case .notInstalled: footer(primary: "前往下载 Hammerspoon", primaryEnabled: true) { model.openHammerspoon() }
        case .notRunning: footer(primary: "打开 Hammerspoon", primaryEnabled: true) { model.openHammerspoon() }
        case .notAuthorized: footer(primary: "打开辅助功能设置", primaryEnabled: true) { model.openAccessibility() }
        case .paused: footer(primary: "恢复句译", primaryEnabled: true) { model.togglePause() }
        case .heartbeatExpired, .notLoaded:
            footer(primary: "打开 Hammerspoon", primaryEnabled: true) { model.openHammerspoon(); model.permissionTroubleshooting = true }
        }
    }

    private var practice: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepTitle("试一次，马上就会", subtitle: "拖动选中下面这句英文，再快速连按两次 Option。")
            VStack(alignment: .leading, spacing: 14) {
                SelectablePracticeText(text: "Good tools should feel effortless.")
                    .frame(height: 52).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                HStack { Spacer(); keycap("⌥"); keycap("⌥"); Spacer() }
                Text("译文会出现在选中文字附近。").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
            }.modifier(Surface())
            if !model.hotkeyReady { Label("快捷键当前未就绪，请先返回检查。", systemImage: "exclamationmark.circle.fill").foregroundStyle(Color(nsColor: .systemOrange)); Button("返回检查快捷键") { model.showPermissionStep() } }
            if model.practiceTroubleshooting {
                VStack(alignment: .leading, spacing: 5) {
                    Text("没有出现译文？").font(.subheadline.weight(.medium))
                    Text("确认整句英文已经被选中；两次 Option 要快速按下并松开。也可以返回检查 Hammerspoon 和辅助功能权限。")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack { Button("重新打开 Hammerspoon") { model.openHammerspoon() }; Button("打开诊断") { model.showDiagnostics = true } }
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
            Text("句译会留在 Dock 和菜单栏，关闭窗口不会停止翻译。")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
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
            Button("稍后再说") { model.deferOnboarding() }.keyboardShortcut(.cancelAction)
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
            HStack { Image(systemName: "cloud.fill").font(.title).foregroundStyle(.blue); VStack(alignment: .leading) { Text("设置火山云端翻译").font(.title2.bold()); Text("可按自己的语料对比，需要联网").foregroundStyle(.secondary) } }
            Text("使用云端时，选中的英文会发送至火山翻译。访问密钥只保存在这台 Mac。")
            VStack(alignment: .leading, spacing: 6) { Text("Access Key ID").font(.subheadline.weight(.medium)); TextField("输入 Access Key ID", text: $access).textFieldStyle(.roundedBorder) }
            VStack(alignment: .leading, spacing: 6) { Text("Secret Access Key").font(.subheadline.weight(.medium)); HStack { Group { if reveal { TextField("输入 Secret Access Key", text: $secret) } else { SecureField("输入 Secret Access Key", text: $secret) } }.textFieldStyle(.roundedBorder); Button(reveal ? "隐藏" : "显示") { reveal.toggle() } } }
            Button("如何获取访问密钥？") { NSWorkspace.shared.open(URL(string: "https://console.volcengine.com/")!) }.buttonStyle(.link)
            if model.cloudConfigExists && !model.cloudBusy {
                HStack { Label("这台 Mac 已保存一组云端密钥。", systemImage: "checkmark.shield"); Spacer(); Button("重新验证") { model.validateExistingCloud() } }
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !model.cloudError.isEmpty { Label(model.cloudError, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red).font(.callout) }
            Spacer()
            HStack { if model.cloudConfigExists { Button("移除已有云端配置…", role: .destructive) { confirmRemoval = true } }; Spacer(); Button("取消") { model.showCloudSetup = false }.keyboardShortcut(.cancelAction).disabled(model.cloudBusy); Button(model.cloudBusy ? "正在验证…" : "保存并验证") { model.configureCloud(accessKey: access, secretKey: secret) }.keyboardShortcut(.defaultAction).disabled(model.cloudBusy) }
        }.padding(28).frame(width: 500, height: 430)
            .interactiveDismissDisabled(model.cloudBusy)
            .alert("移除云端翻译设置？", isPresented: $confirmRemoval) {
                Button("取消", role: .cancel) {}
                Button("移除", role: .destructive) { model.removeCloud() }
            } message: { Text(model.appleAvailable ? "句译将切换到 Apple 离线，选中的文字不再发送到火山翻译。" : "移除后将暂时没有可用的翻译方式。") }
    }
}

private struct DiagnosticsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("诊断与帮助").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text("遇到问题时可以先重新检查或自动修复。技术日志只记录运行状态，不记录你翻译的正文或访问密钥。").foregroundStyle(.secondary)
                GroupBox("当前状态") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("翻译组件：\(model.serviceReady ? "已连接" : "未连接")", systemImage: model.serviceReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        Label("快捷键助手：\(model.hotkeyReady ? "已载入" : "需要设置")", systemImage: model.hotkeyReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        Text("当前引擎：\(model.selectedEngine == "apple" ? "Apple 离线" : "火山云端")")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                HStack { Button("重新检查") { Task { await model.refresh() } }; Button("自动修复") { model.repairService() }; Button("打开技术日志") { model.openLogs() } }
                if !model.serviceInstalled {
                    Label("句译后台组件尚未安装完整。请打开安装说明并按步骤重新安装；现有设置不会被清除。", systemImage: "shippingbox.and.arrow.backward")
                        .foregroundStyle(Color(nsColor: .systemOrange)).fixedSize(horizontal: false, vertical: true)
                    Button("打开安装说明") { model.openInstallationGuide() }
                } else if model.serviceReady { Button("停止后台翻译组件", role: .destructive) { model.stopService() } }
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
                    Text("这只检查后端翻译，不代表双击 Option 已设置成功。").font(.callout).foregroundStyle(.secondary)
                    Button(model.testing ? "正在测试…" : "运行固定样例测试") { model.testTranslation() }.disabled(model.testing || model.cloudBusy || !model.serviceReady || !model.engineReady)
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

private struct AppView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) { Text(model.statusTitle).font(.system(size: 23, weight: .semibold)); Text(model.statusMessage).foregroundStyle(.secondary) }
                    Spacer(); Image(systemName: model.statusSymbol).font(.system(size: 27)).foregroundStyle(model.statusColor).accessibilityLabel(model.statusTitle)
                }

                if !model.onboardingCompleted {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "sparkles").font(.title2).foregroundStyle(Color(nsColor: .systemOrange))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("完成快捷键设置").font(.headline)
                            Text("完成后，就能在多数可选中文本的 App 中使用句译。").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("继续设置") { model.startOnboarding() }.keyboardShortcut(.defaultAction)
                    }.modifier(Surface())
                } else if !model.hotkeyReady {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "exclamationmark.circle.fill").font(.title2).foregroundStyle(Color(nsColor: .systemOrange))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("快捷键需要重新开启").font(.headline)
                            Text("你的设置仍在，重新检查 Hammerspoon 即可。").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("重新开启") { model.repairShortcut() }
                    }.modifier(Surface())
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("翻译方式").font(.headline)
                    HStack(alignment: .top, spacing: 12) {
                        EngineCard(symbol: "lock.shield.fill", title: "Apple 离线", badge: "推荐", subtitle: "隐私优先 · 无需密钥", detail: !model.serviceReady ? "恢复翻译组件后会自动检查。" : (model.appleNeedsPreparation ? "需要下载系统中英语言包。" : (model.appleAvailable ? "文本只在这台 Mac 上处理。" : "这台 Mac 暂未准备好离线翻译。")), selected: model.selectedEngine == "apple", action: model.chooseApple)
                        EngineCard(symbol: "cloud.fill", title: "火山云端", badge: !model.serviceReady ? "待检查" : (model.cloudConfigured ? (model.cloudVerifiedForUI ? "已验证" : "待验证") : "需设置"), subtitle: "可按自己的语料对比 · 需要联网", detail: "选中的英文会发送至火山翻译。", selected: model.selectedEngine == "volc", action: model.chooseCloud)
                    }
                    if model.appleNeedsPreparation { Button("准备 Apple 离线翻译…") { model.prepareApple() } }
                    if model.cloudConfigExists { HStack { Spacer(); Button("管理云端设置…") { model.cloudError = ""; model.showCloudSetup = true }.buttonStyle(.link) } }
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 18) {
                        HStack(spacing: 6) { keycap("⌥"); keycap("⌥") }
                        VStack(alignment: .leading, spacing: 3) { Text("选中英文，连按两次 Option").font(.headline); Text("译文会出现在选中文字附近").foregroundStyle(.secondary).font(.subheadline) }
                        Spacer()
                    }
                }.modifier(Surface())

                if !model.notice.isEmpty { Label(model.notice, systemImage: "info.circle.fill").font(.callout).foregroundStyle(.secondary) }
                HStack {
                    Button("诊断与帮助…") { model.showDiagnostics = true }.buttonStyle(.link)
                    if model.onboardingCompleted { Button("重新学习双击 Option…") { model.relearnShortcut() }.buttonStyle(.link) }
                    Spacer()
                    Button(model.paused ? "恢复句译" : "暂停句译") { model.togglePause() }
                }
            }.padding(.horizontal, 30).padding(.vertical, 26)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private func keycap(_ text: String) -> some View {
        Text(text).font(.system(size: 20, weight: .semibold, design: .rounded)).frame(width: 42, height: 40).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isLoginLaunch = launchedFromLogin
        NSApp.setActivationPolicy(.regular); installMainMenu(); createWindow()
        model.onChange = { [weak self] in self?.updateChrome() }; updateChrome()
        if !isLoginLaunch { showWindow() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationDidBecomeActive(_ notification: Notification) { model.applicationBecameActive() }
    func applicationWillTerminate(_ notification: Notification) {
        if model.onboardingPresented { model.deferOnboarding() }
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
        let initialSize = model.onboardingPresented ? NSSize(width: 620, height: 520) : NSSize(width: 680, height: 650)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: initialSize), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "句译"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 580, height: 480); window.delegate = self
        ensureWindowVisible(forceCenter: true)
        window.contentView = NSHostingView(rootView: RootView(model: model))
        lastOnboardingMode = model.onboardingPresented
    }
    private func installMainMenu() {
        let main = NSMenu(), app = NSMenuItem(), submenu = NSMenu()
        let quit = NSMenuItem(title: "退出句译", action: #selector(terminate), keyEquivalent: "q"); quit.target = self; submenu.addItem(quit)
        app.submenu = submenu; main.addItem(app); NSApp.mainMenu = main
    }
    private func item(_ title: String, action: Selector? = nil, enabled: Bool = true) -> NSMenuItem { let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self; i.isEnabled = enabled; return i }
    private func updateMenu() {
        let symbol = model.paused ? "pause.circle" : (model.ready ? "character.bubble.fill" : "exclamationmark.triangle.fill")
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: model.statusTitle); statusItem.button?.image?.isTemplate = true
        let menu = NSMenu(); menu.addItem(item(model.statusTitle, enabled: false)); menu.addItem(item("打开句译…", action: #selector(showWindow)))
        let onboardingTitle = model.onboardingCompleted
            ? (model.hotkeyReady ? "重新学习双击 Option…" : "修复快捷键设置…")
            : "继续设置…"
        menu.addItem(item(onboardingTitle, action: #selector(onboarding)))
        let engine = item("翻译方式"), sub = NSMenu(); let apple = item("Apple 离线", action: #selector(apple)); apple.state = model.selectedEngine == "apple" ? .on : .off; let cloud = item("火山云端…", action: #selector(cloud)); cloud.state = model.selectedEngine == "volc" ? .on : .off; sub.addItem(apple); sub.addItem(cloud); engine.submenu = sub; menu.addItem(engine)
        menu.addItem(.separator()); menu.addItem(item(model.paused ? "恢复句译" : "暂停句译", action: #selector(pause))); menu.addItem(item("诊断与帮助…", action: #selector(diagnostics))); menu.addItem(.separator()); menu.addItem(item("退出句译", action: #selector(terminate))); statusItem.menu = menu
    }
    private func updateChrome() {
        updateMenu()
        guard window != nil else { return }
        let mode = model.onboardingPresented
        guard lastOnboardingMode != mode else { return }
        lastOnboardingMode = mode
        let target = model.onboardingPresented ? NSSize(width: 620, height: 520) : NSSize(width: 680, height: 650)
        let current = window.contentLayoutRect.size
        let suggested = NSSize(width: max(current.width, target.width), height: max(current.height, target.height))
        if suggested.width > current.width || suggested.height > current.height {
            window.setContentSize(suggested)
            ensureWindowVisible()
        }
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
    @objc private func apple() { model.chooseApple() }; @objc private func cloud() { model.chooseCloud(); showWindow() }; @objc private func pause() { model.togglePause() }; @objc private func diagnostics() { model.showDiagnostics = true; showWindow() }; @objc private func terminate() { NSApp.terminate(nil) }
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
