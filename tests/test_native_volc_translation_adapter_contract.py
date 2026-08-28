"""Static P0 contracts for the default-off native Volc Debug adapter."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
SOURCE_NAMES = (
    "NativeVolcDebugCredentialStore.swift",
    "NativeVolcDebugInterlock.swift",
    "NativeVolcDebugTransport.swift",
    "NativeVolcDebugWorkflow.swift",
    "NativeVolcTranslationAdapterModel.swift",
    "NativeVolcTranslationAdapterHost.swift",
)
SOURCES = {
    name: (ROOT / "macos" / name).read_text(encoding="utf-8")
    for name in SOURCE_NAMES
}
ALL_SOURCE = "\n".join(SOURCES.values())
APP = (ROOT / "macos/JuyiMenuBar.swift").read_text(encoding="utf-8")
PROJECT = (ROOT / "Juyi.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
LEGACY = (ROOT / "scripts/build_macos_app.sh").read_text(encoding="utf-8")
CI = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
DOC = (ROOT / "docs/NATIVE_VOLC_TRANSLATION_ADAPTER.md").read_text(encoding="utf-8")
CONFIG = "\n".join(
    (ROOT / f"Config/{name}.xcconfig").read_text(encoding="utf-8")
    for name in ("Debug", "Release", "Shared")
)

GATE = (
    "#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN "
    "&& JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER"
)
SENTINEL = "juyi-native-volc-translation-adapter-v1"
FIXTURE = "Good tools should feel effortless."
MENU = "开发：测试火山云端翻译…"


def _conditions_for_occurrences(source: str, token: str) -> list[tuple[str, ...]]:
    stack: list[str] = []
    occurrences: list[tuple[str, ...]] = []
    for line in source.splitlines():
        stripped = line.strip()
        if stripped.startswith("#if "):
            stack.append(stripped)
        elif stripped.startswith("#elseif "):
            if stack:
                stack[-1] = "#if " + stripped.removeprefix("#elseif ")
        elif stripped == "#endif":
            if stack:
                stack.pop()
        elif token in line:
            occurrences.append(tuple(stack))
    return occurrences


def test_every_new_source_and_app_entry_use_the_exact_triple_gate() -> None:
    for name, source in SOURCES.items():
        lines = source.strip().splitlines()
        assert lines[0] == GATE, name
        assert lines[-1] == "#endif", name
        assert source.count(GATE) == 1, name
        assert source.count("#if ") == 1, name
        assert source.count("#endif") == 1, name
        assert "#if DEBUG ||" not in source
    for token in (
        "NativeVolcTranslationAdapterCoordinator",
        "NativeVolcTranslationAdapterSheet",
        MENU,
        "testNativeVolcTranslationAdapter",
        "nativeVolcWillSleep",
        "nativeVolcDidWake",
        "nativeVolcSessionResigned",
    ):
        occurrences = _conditions_for_occurrences(APP, token)
        assert occurrences, token
        assert all(GATE in stack for stack in occurrences), token
    assert "JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER" not in CONFIG


def test_fixture_menu_and_debug_namespace_are_unique_and_production_is_untouched() -> None:
    transport = SOURCES["NativeVolcDebugTransport.swift"]
    host = SOURCES["NativeVolcTranslationAdapterHost.swift"]
    assert transport.count(FIXTURE) == 1
    assert host.count(FIXTURE) == 1  # required real-API disclosure
    for name in SOURCE_NAMES:
        if name not in {"NativeVolcDebugTransport.swift", "NativeVolcTranslationAdapterHost.swift"}:
            assert FIXTURE not in SOURCES[name]
    # The exact sample predates 4C in onboarding and the legacy cloud verifier,
    # so it is a positive fixture check but cannot be an off-artifact canary.
    assert APP.count(FIXTURE) > 0
    assert ALL_SOURCE.count(SENTINEL) == 1
    assert APP.count(MENU) == 1
    install_menu = APP.split("private func installMainMenu()", 1)[1].split(
        "private func item(", 1
    )[0]
    status_menu = APP.split("private func updateMenu()", 1)[1].split(
        "private func updateChrome()", 1
    )[0]
    assert MENU in install_menu
    assert MENU not in status_menu
    for service in (
        "io.github.Eim-aa.Juyi.debug.native-volc.active",
        "io.github.Eim-aa.Juyi.debug.native-volc.pending",
        "io.github.Eim-aa.Juyi.debug.native-volc.verified",
        "io.github.Eim-aa.Juyi.debug.native-volc.transaction",
    ):
        assert service in SOURCES["NativeVolcDebugCredentialStore.swift"]
    assert "Library/Application Support/io.github.Eim-aa.Juyi/NativeVolcDebug" in (
        SOURCES["NativeVolcDebugInterlock.swift"]
    )
    for production_token in (
        '"io.github.Eim-aa.juyi.volc"',
        '"io.github.Eim-aa.juyi.volc.pending"',
        "cloudVerifiedFingerprint",
        "volc.env",
        "hs-engine",
        "LaunchAgent",
        "launchctl",
    ):
        assert production_token not in ALL_SOURCE, production_token


def test_open_is_zero_io_and_only_explicit_actions_reach_the_workflow() -> None:
    model = SOURCES["NativeVolcTranslationAdapterModel.swift"]
    open_body = model.split("func open()", 1)[1].split("func perform(", 1)[0]
    assert "workflow." not in open_body
    assert "Task" not in open_body
    assert "FileManager" not in open_body
    assert "Keychain" not in open_body
    host = SOURCES["NativeVolcTranslationAdapterHost.swift"]
    assert "let allowed = Set(presentation.actions.map(\\.action)).union([.close])" in model
    assert "guard allowed.contains(action) else { return }" in model
    assert ".saveAndValidate" in host
    assert "SecureField" in host
    assert "不会读取用于翻译的选区或剪贴板" in host
    assert "AK 作为账号标识会随签名请求发送给火山" in host
    assert "SK 本身不会发送或写入日志" in host


def test_adapter_has_no_live_input_runtime_switch_or_unapproved_route() -> None:
    for token in (
        "URLSession.shared",
        "127.0.0.1",
        "localhost",
        "NSPasteboard",
        "NativeOption",
        "NativeSelection",
        "NativeTranslationOverlay",
        "UserDefaults",
        "Process(",
        "getenv",
        "URLCache.shared",
    ):
        assert token not in ALL_SOURCE, token
    transport = SOURCES["NativeVolcDebugTransport.swift"]
    assert (
        '"https://translate.volcengineapi.com/'
        '?Action=TranslateText&Version=2020-06-01"'
    ) in transport
    assert "URLSessionConfiguration.ephemeral" in transport
    assert "configuration.httpAdditionalHeaders = nil" in transport
    assert "configuration.httpCookieStorage = nil" in transport
    assert "configuration.httpShouldSetCookies = false" in transport
    assert "configuration.urlCredentialStorage = nil" in transport
    assert "configuration.waitsForConnectivity = false" in transport
    assert "completionHandler(nil)" in transport
    assert transport.count("didReceive challenge: URLAuthenticationChallenge") == 2
    start = transport.split("func start(_ task: URLSessionDataTask)", 1)[1].split(
        "func cancel()", 1
    )[0]
    linearized = start.split("let decision = lock.withLock", 1)[1].split(
        "switch decision", 1
    )[0]
    assert linearized.index("state.cancelRequested") < linearized.index("task.resume()")


def test_keychain_is_fail_closed_redacted_and_never_prompts_by_design() -> None:
    store = SOURCES["NativeVolcDebugCredentialStore.swift"]
    assert "kSecAttrSynchronizable as String: false" in store
    assert 'kSecUseAuthenticationUI as String: "u_AuthUIF"' in store
    assert "authenticationContext.interactionNotAllowed = true" in store
    assert "kSecUseDataProtectionKeychain" not in store
    assert "kSecAttrAccessible" not in store
    assert "errSecItemNotFound" in store
    assert "errSecDuplicateItem" in store
    assert "[REDACTED]" in store
    assert "localizedDescription" not in ALL_SOURCE
    assert re.search(r"\bprint\(", ALL_SOURCE) is None
    assert "NSLog" not in ALL_SOURCE
    assert "os_log" not in ALL_SOURCE


def test_interlock_and_transaction_shapes_preserve_fail_closed_recovery() -> None:
    interlock = SOURCES["NativeVolcDebugInterlock.swift"]
    workflow = SOURCES["NativeVolcDebugWorkflow.swift"]
    store = SOURCES["NativeVolcDebugCredentialStore.swift"]
    for token in (
        'requestGate = "cloud-request-gate.lock"',
        'transportLock = "cloud-transport.lock"',
        'removalOwnerLock = "cloud-removal-owner.lock"',
        'revocationEpoch = "cloud-revocation-epoch"',
        'writerIntent = "cloud-writer-intent"',
        'removalMarker = "cloud-removal-pending"',
        "LOCK_EX | LOCK_NB",
        "O_NOFOLLOW",
        "fsync(directory)",
        "renameat(",
    ):
        assert token in interlock, token
    for phase in (
        "validated",
        "activeWritten",
        "verifiedWritten",
        "rollbackRequested",
        "rollbackActiveRestored",
        "rollbackVerifiedRestored",
        "rollbackPendingRemoved",
    ):
        assert f"case {phase}" in store
    assert "let removalOrder: [NativeVolcDebugKeychainSlot]" in workflow
    assert ".verified, .active, .pending, .transaction" in workflow
    assert "operationToken" in workflow
    assert "cancellationGeneration" in workflow
    inspection = workflow.split("func inspect()", 1)[1].split(
        "func saveAndValidate(", 1
    )[0]
    assert "interlock.beginReader()" in inspection
    assert inspection.count("interlock.revalidationState(reader)") == 2
    assert "inspectWithoutCredentials" not in inspection
    assert inspection.index("interlock.revalidationState(reader)") < inspection.index(
        "store.readJournal()"
    )


def test_privacy_copy_and_lifecycle_are_explicit_and_typed() -> None:
    model = SOURCES["NativeVolcTranslationAdapterModel.swift"]
    host = SOURCES["NativeVolcTranslationAdapterHost.swift"]
    for text in (
        "此页面连接真实火山翻译 API，不是模拟器。",
        "火山服务会获得你的 IP 地址和正常连接元数据。",
        "每次点击最多发送一次，可能产生少量 API 用量或费用。",
        "请求可能已经发送，并可能产生少量用量或费用",
        "迟到译文不会显示或保存",
        "Debug 云端配置已移除",
        "未发送新请求。",
    ):
        assert text in model + host, text
    for reason in (".pause", ".stop", ".engineChanged", ".terminate"):
        assert f"invalidate({reason})" in APP
    for reason in (".sleep", ".wake", ".sessionResigned"):
        assert f"invalidate({reason})" in APP
    assert "NSWorkspace.willSleepNotification" in APP
    assert "NSWorkspace.didWakeNotification" in APP
    assert "NSWorkspace.sessionDidResignActiveNotification" in APP
    assert "@ObservedObject private var nativeVolcTranslationAdapter" in APP
    assert "get: { nativeVolcTranslationAdapter.isPresented }" in APP
    assert model.count("targetText: nil") >= 8
    assert "accessKey = \"\"" in model
    assert "secretKey = \"\"" in model


def test_xcode_legacy_ci_docs_and_tests_are_all_connected() -> None:
    for name in SOURCE_NAMES:
        assert PROJECT.count(name) == 6, name
        assert f'"$ROOT/macos/{name}"' in LEGACY
        assert name in CI
        assert name in DOC
    for test_name in (
        "NativeVolcDebugCredentialStoreTests.swift",
        "NativeVolcDebugInterlockTests.swift",
        "NativeVolcDebugTransportTests.swift",
        "NativeVolcDebugWorkflowTests.swift",
        "NativeVolcTranslationAdapterModelTests.swift",
    ):
        assert test_name in CI
    assert SENTINEL in CI
    assert FIXTURE in CI
    assert MENU in CI
    assert "grep -aFq" in CI
    assert "otool -L" in CI
    assert "volc-adapter-off.loads" in CI
    assert "NativeVolcTranslationAdapterSheet" in CI
    assert "Library/Application Support/io.github.Eim-aa.Juyi/NativeVolcDebug" in CI
    assert "JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER" in LEGACY + CI
    assert "scripts/start_service.command" not in (
        PROJECT + LEGACY + CI + DOC + ALL_SOURCE
    )


def test_documentation_keeps_4c_default_off_and_real_machine_gates_honest() -> None:
    for text in (
        "仅供开发验证",
        "默认关闭",
        "生产启用仍是 NO-GO",
        "打开 sheet 本身不会读取钥匙串、文件或发起网络请求",
        "macOS 15",
        "Intel",
        "真机",
        "u_AuthUIF",
        "可能产生少量 API 用量或费用",
        "不会读取或改写生产 Keychain",
    ):
        assert text in DOC, text
