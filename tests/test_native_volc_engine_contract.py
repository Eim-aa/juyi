"""Contracts for the native Volcengine engine (phase 4A)."""

import re
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCES = ("VolcV4RequestBuilder.swift", "VolcTranslationResponseParser.swift", "VolcTranslationEngine.swift")
SUITES = ("VolcV4RequestBuilderTests", "VolcTranslationResponseParserTests", "VolcTranslationEngineTests")
PROJECT = (ROOT / "Juyi.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")
BUILD = (ROOT / "scripts" / "build_macos_app.sh").read_text(encoding="utf-8")
RUNNER = (ROOT / "scripts" / "run_swift_tests.sh").read_text(encoding="utf-8")
BUILDER = (ROOT / "macos" / "VolcV4RequestBuilder.swift").read_text(encoding="utf-8")
ENGINE = (ROOT / "macos" / "VolcTranslationEngine.swift").read_text(encoding="utf-8")
PARSER = (ROOT / "macos" / "VolcTranslationResponseParser.swift").read_text(encoding="utf-8")


def test_sources_are_in_the_xcode_project_group_and_sources_phase():
    macos_group = PROJECT.split("/* macos */ = {", 1)[1].split("};", 1)[0]
    sources_phase = PROJECT.split("/* Sources */ = {", 1)[1].split("};", 1)[0]
    for name in SOURCES:
        match = re.search(
            rf"(\w{{24}}) /\* {re.escape(name)} \*/ = \{{isa = PBXFileReference; "
            rf"lastKnownFileType = sourcecode.swift; path = {re.escape(name)}; "
            r'sourceTree = "<group>"; \};',
            PROJECT,
        )
        assert match, name
        file_ref = match.group(1)
        build = re.search(
            rf"(\w{{24}}) /\* {re.escape(name)} in Sources \*/ = \{{isa = PBXBuildFile; "
            rf"fileRef = {file_ref} /\* {re.escape(name)} \*/; \}};",
            PROJECT,
        )
        assert build, name
        assert f"{file_ref} /* {name} */," in macos_group
        assert f"{build.group(1)} /* {name} in Sources */," in sources_phase
        assert PROJECT.count(f"/* {name} in Sources */") == 2


def test_sources_are_in_the_legacy_build_and_suites_in_the_runner():
    for name in SOURCES:
        assert BUILD.count(f'"$ROOT/macos/{name}"') == 1
        assert (ROOT / "macos" / name).is_file()
    assert BUILD.count("-framework CryptoKit") == 1
    for suite in SUITES:
        assert f"run_suite {suite} " in RUNNER
        assert (ROOT / "tests" / f"{suite}.swift").is_file()
    engine_suite = RUNNER.split("run_suite VolcTranslationEngineTests", 1)[1].split("\n\n", 1)[0]
    for name in SOURCES:
        assert f"macos/{name}" in engine_suite
    assert "run_suite VolcV4RequestBuilderTests STRICT" in RUNNER
    assert "run_suite VolcTranslationResponseParserTests STRICT" in RUNNER


def test_endpoint_lives_only_in_the_builder():
    hits = []
    for path in (ROOT / "macos").rglob("*.swift"):
        if "translate.volcengineapi.com" in path.read_text(encoding="utf-8"):
            hits.append(path.name)
    assert hits == ["VolcV4RequestBuilder.swift"]
    assert BUILDER.count("translate.volcengineapi.com") == 1
    assert 'static let region = "cn-north-1"' in BUILDER
    assert 'static let service = "translate"' in BUILDER
    assert 'VolcV4QueryItem(name: "Action", value: "TranslateText")' in BUILDER
    assert 'VolcV4QueryItem(name: "Version", value: "2020-06-01")' in BUILDER
    assert 'let url = URL(string: "https://\\(host)' in BUILDER


def test_source_language_is_always_english():
    assert 'nonisolated static let sourceLanguage = "en"' in ENGINE
    assert 'nonisolated static let targetLanguage = "zh"' in ENGINE
    assert "source: Self.sourceLanguage," in ENGINE
    assert "target: Self.targetLanguage," in ENGINE
    assert "source: nil" not in ENGINE
    assert 'source: ""' not in ENGINE
    # Swift source escapes the JSON keys: \"SourceLanguage\".
    for key in ("SourceLanguage", "TargetLanguage", "TextList"):
        assert f'\\"{key}\\"' in BUILDER


def test_engine_contract_timeout_cancellation_and_isolation():
    assert "@MainActor\nfinal class VolcTranslationEngine" in ENGINE
    assert "func translate(_ text: String) async -> VolcTranslationOutcome" in ENGINE
    assert "func validate(credentials: VolcV4Credentials) async -> VolcTranslationOutcome" in ENGINE
    assert "func cancelCurrent()" in ENGINE
    assert "nonisolated static let requestTimeout: TimeInterval = 12" in ENGINE
    assert "configuration.timeoutIntervalForRequest = requestTimeout" in ENGINE
    assert "configuration: URLSessionConfiguration = .ephemeral" in ENGINE
    assert "withTaskCancellationHandler" in ENGINE
    assert "task?.cancel()" in ENGINE
    assert 'static let validationText = "Good tools should feel effortless."' in ENGINE
    assert "Result<String, VolcTranslationError>" in PARSER
    for source in (BUILDER, ENGINE, PARSER):
        assert "#if" not in source
        assert "JUYI_" not in source
        assert "NativeTranslationFailure" not in source
    assert "import CryptoKit" in BUILDER
    assert "import CryptoKit" not in ENGINE
