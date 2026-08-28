"""Static P0 contracts for the compile-time-gated native translation domain."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATHS = [
    ROOT / "macos" / "NativeTranslationDomain.swift",
    ROOT / "macos" / "VolcV4RequestBuilder.swift",
    ROOT / "macos" / "VolcTranslationResponseParser.swift",
]
SOURCES = {path.name: path.read_text(encoding="utf-8") for path in SOURCE_PATHS}
ALL_SOURCE = "\n".join(SOURCES.values())
PROJECT = (ROOT / "Juyi.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")
LEGACY = (ROOT / "scripts" / "build_macos_app.sh").read_text(encoding="utf-8")
CI = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
DEBUG_CONFIG = (ROOT / "Config" / "Debug.xcconfig").read_text(encoding="utf-8")
RELEASE_CONFIG = (ROOT / "Config" / "Release.xcconfig").read_text(encoding="utf-8")
SHARED_CONFIG = (ROOT / "Config" / "Shared.xcconfig").read_text(encoding="utf-8")
APP = (ROOT / "macos" / "JuyiMenuBar.swift").read_text(encoding="utf-8")
DOC = (ROOT / "docs" / "NATIVE_TRANSLATION_DOMAIN.md").read_text(encoding="utf-8")


def test_every_domain_file_has_one_exact_outer_debug_gate():
    for name, source in SOURCES.items():
        assert source.startswith("#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN\n"), name
        assert source.rstrip().endswith("#endif"), name
        assert source.count("#if ") == 1, name
        assert source.count("#endif") == 1, name
        assert "#if DEBUG ||" not in source
        assert "#if JUYI_NATIVE_TRANSLATION_DOMAIN" not in source


def test_domain_has_no_runtime_entry_or_runtime_switch():
    app_gates = {
        "#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN "
        "&& JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER",
        "#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN "
        "&& JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER",
        "#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN "
        "&& JUYI_NATIVE_TRANSLATION_OVERLAY "
        "&& JUYI_NATIVE_TRANSLATION_RESULT_LAB",
    }
    domain_flag_lines = [
        line.strip()
        for line in APP.splitlines()
        if "JUYI_NATIVE_TRANSLATION_DOMAIN" in line
    ]
    assert domain_flag_lines
    assert set(domain_flag_lines) == app_gates
    assert "NativeTranslationDomain" not in APP
    assert "VolcV4RequestBuilder" not in APP
    assert "VolcTranslationResponseParser" not in APP
    for config in (DEBUG_CONFIG, RELEASE_CONFIG, SHARED_CONFIG):
        assert "JUYI_NATIVE_TRANSLATION_DOMAIN" not in config
    assert 'if [[ "$CONFIGURATION" == "Debug" ]]' in LEGACY
    assert "JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER" in LEGACY
    assert "JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER" in LEGACY
    assert "UserDefaults" not in ALL_SOURCE
    assert "ProcessInfo" not in ALL_SOURCE
    assert "public let nativeTranslationDomainBuildSentinel" in ALL_SOURCE
    assert "@used" not in ALL_SOURCE
    assert "@_used" not in ALL_SOURCE


def test_domain_sources_are_pure_and_forbid_live_or_sensitive_apis():
    forbidden = [
        "URLSession",
        "URLRequest",
        "URLCache",
        "NSPasteboard",
        "NSEvent",
        "AppKit",
        "ApplicationServices",
        "AXUIElement",
        "TranslationSession",
        "import Translation",
        "import Security",
        "Keychain",
        "FileManager",
        "Process(",
        "NotificationCenter",
        "localhost",
        "127.0.0.1",
        "Date.now",
        "NativeOption",
        "NativeSelection",
        "NativeTranslationOverlay",
    ]
    for token in forbidden:
        assert token not in ALL_SOURCE, token
    assert set(re.findall(r"^import (\w+)$", ALL_SOURCE, re.MULTILINE)) <= {
        "Foundation",
        "CryptoKit",
    }


def test_closed_engine_and_success_types_have_no_cross_engine_switching_shape():
    domain = SOURCES["NativeTranslationDomain.swift"]
    engine = domain.split("enum NativeTranslationEngine", 1)[1].split("}", 1)[0]
    assert re.findall(r"^    case (\w+)$", engine, re.MULTILINE) == ["apple", "volc"]
    success = domain.split("struct NativeTranslationSuccess", 1)[1].split("}\n\n", 1)[0]
    assert success.count("let engine:") == 1
    for token in (
        "requestedEngine",
        "actualEngine",
        "fallbackReason",
        "usedAppleFallback",
        "warning",
    ):
        assert token not in success
    for token in ("fallbackReason", "usedAppleFallback"):
        assert token not in ALL_SOURCE
    assert "argos" not in ALL_SOURCE
    assert "unknown" not in ALL_SOURCE.lower()


def test_no_text_result_storage_or_reuse_primitive_exists():
    lowered = ALL_SOURCE.lower()
    for token in ("lru", "urlcache", "cached", "cache"):
        assert token not in lowered
    assert "static var" not in ALL_SOURCE
    domain = SOURCES["NativeTranslationDomain.swift"]
    assert "retainedInput = nil" in domain
    assert "retainedOutcome" not in domain
    assert "case skipped(NativeTranslationSkipReason)" in domain
    assert "case tooShort" in domain


def test_input_privacy_and_generation_contracts_are_explicit():
    domain = SOURCES["NativeTranslationDomain.swift"]
    assert ".replacingOccurrences(of: \"\\r\\n\", with: \"\\n\")" in domain
    assert ".replacingOccurrences(of: \"\\r\", with: \"\\n\")" in domain
    assert "static let scalarLimit = 5_000" in domain
    assert "allScalars.prefix(scalarLimit)" in domain
    assert "scalar.properties.isWhitespace" in domain
    assert "scalar.properties.isAlphabetic" in domain
    for value in ("0x4E00...0x9FFF", "0x3000...0x303F", "0xFF00...0xFFEF"):
        assert value in domain
    assert "> 0.5" in domain
    assert "case installed" in domain
    assert "case supportedNeedsPreparation" in domain
    assert "case unsupported" in domain
    assert "case confirmedAbsent" in domain
    assert "fingerprint == verified" in domain
    for reason in (
        "case pause",
        "case stop",
        "case accessibilityRevoked",
        "case engineChanged",
        "case credentialsChanged",
        "case removalStateChanged",
        "case ownerChanged",
    ):
        assert reason in domain
    assert domain.count("guard isCurrent(requestGeneration)") >= 4


def test_v4_profile_is_deterministic_python_compatible_and_redacted():
    builder = SOURCES["VolcV4RequestBuilder.swift"]
    for value in (
        'let method = "POST"',
        'let host = "translate.volcengineapi.com"',
        'let canonicalURI = "/"',
        'let region = "cn-north-1"',
        'let service = "translate"',
        'VolcV4QueryItem(name: "Action", value: "TranslateText")',
        'VolcV4QueryItem(name: "Version", value: "2020-06-01")',
        'formatter.locale = Locale(identifier: "en_US_POSIX")',
        'formatter.calendar = Calendar(identifier: .gregorian)',
        'formatter.timeZone = TimeZone(secondsFromGMT: 0)',
        'formatter.dateFormat = "yyyyMMdd\'T\'HHmmss\'Z\'"',
        '\\"TargetLanguage\\"',
        '\\"TextList\\"',
        '\\"SourceLanguage\\"',
        'return Data(authenticationCode)',
        '[REDACTED]',
        "static let maximumCredentialBytes = 256",
        "static let maximumLanguageIdentifierBytes = 32",
        "credentialsAreValid(",
        "secretKey: credentials.secretKey",
        "validAccessKey(accessKey) && validSecretKey(secretKey)",
        "(0x21...0x7E).contains($0.value)",
        "(1...maximum).contains(value.utf8.count)",
    ):
        assert value in builder, value
    assert builder.index('\\"TargetLanguage\\"') < builder.index('\\"TextList\\"')
    assert builder.index('\\"TextList\\"') < builder.index('\\"SourceLanguage\\"')
    assert "JSONSerialization" not in builder
    assert "JSONEncoder" not in builder
    assert "URLComponents" not in builder
    assert "addingPercentEncoding" not in builder


def test_response_parser_has_stable_allowlist_and_never_exposes_upstream_fields():
    parser = SOURCES["VolcTranslationResponseParser.swift"]
    for status in ("case 401, 403", "case 408, 504", "case 429", "case 500...599"):
        assert status in parser
    for code in (
        '"InvalidAccessKey"',
        '"SignatureDoesNotMatch"',
        '"RequestTimeout"',
        '"QuotaExceeded"',
    ):
        assert code in parser
    assert "default:\n            return .volcService" in parser
    assert "message" not in parser.lower()
    assert "maximumPayloadBytes" in parser
    failure = SOURCES["NativeTranslationDomain.swift"].split(
        "enum NativeTranslationFailure", 1
    )[1].split("var description", 1)[0]
    for line in re.findall(r"^    case .+$", failure, re.MULTILINE):
        assert "(" not in line


def test_xcode_legacy_ci_and_docs_wire_only_the_explicit_sources():
    names = [path.name for path in SOURCE_PATHS]
    for name in names:
        assert PROJECT.count(name) == 6, name
        assert f'"$ROOT/macos/{name}"' in LEGACY
        assert name in CI
        assert name in DOC
    assert "JUYI_NATIVE_TRANSLATION_DOMAIN'" in CI
    assert "'DEBUG JUYI_NATIVE_TRANSLATION_DOMAIN'" in CI
    assert "juyi-native-translation-domain-v1" in CI
    assert "domain-release-flag.strings" in CI
    assert "ordinary Debug" not in DOC
    assert "仅供开发验证" in DOC
    assert "scripts/start_service.command" not in PROJECT + LEGACY + CI + DOC + ALL_SOURCE


def test_macos15_baseline_and_no_newer_translation_api_dependency():
    assert "MACOSX_DEPLOYMENT_TARGET = 15.0" in SHARED_CONFIG
    for token in ("TranslationSession.cancel", ".isReady", "installedSource"):
        assert token not in ALL_SOURCE
