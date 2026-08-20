"""Static contracts for the Hammerspoon request and popup state machines.

Hammerspoon embeds Lua and is not present in normal Python CI. These checks
cover the safety-critical wiring while local development additionally parses
the file with Hammerspoon's bundled Lua runtime.
"""

import re
from pathlib import Path


SOURCE = Path(__file__).parents[1] / "hammerspoon" / "argos-translator.lua"
LUA = SOURCE.read_text(encoding="utf-8")


def _between(start: str, end: str) -> str:
    return LUA.split(start, 1)[1].split(end, 1)[0]


def test_each_hotkey_starts_a_new_generation_and_cancels_previous_timers():
    begin = _between("local function beginRequest()", "local function requestIsCurrent")
    hotkey = _between("local function onHotkey()", "-- ---------- double-tap Option")
    assert "requestGeneration = requestGeneration + 1" in begin
    assert "stopRequestTimers(activeRequest)" in begin
    assert "local request = beginRequest()" in hotkey
    assert "callTranslate(text, src, request)" in hotkey


def test_progress_health_and_translate_callbacks_are_generation_guarded():
    call = _between("local function callTranslate", "-- ---------- engine selection")
    for delay in ("0.8", "1.5", "3.0"):
        timer = call.split(f"hs.timer.doAfter({delay}", 1)[1].split("end)", 1)[0]
        assert "requestIsCurrent(request)" in timer
    assert "if not requestIsCurrent(request) or request.finished or not activeCanvas" in call
    assert "stopRequestTimers(request)" in call
    assert "request.finished = true" in call
    assert "if not requestIsCurrent(request) or not activeCanvas" in call


def test_popup_supports_copy_close_escape_and_bounded_overflow():
    assert 'kind == "success" or kind == "error"' in LUA
    assert "hs.pasteboard.setContents" in LUA
    assert 'kind = "transition"' in LUA
    assert "hs.keycodes.map.escape" in LUA
    assert "not pointInFrame(p, f)" in LUA
    assert "local maxHeight = math.max(1, math.floor(sf.h - 12))" in LUA
    assert 'overflowHint = "内容过长，点击复制完整译文"' in LUA
    assert "copyText = copyText" in LUA


def test_warnings_are_sanitized_truncated_and_used_in_error_subtitles():
    sanitizer = _between("local function sanitizeWarning", "local function warningDetail")
    assert "[已脱敏]" in sanitizer
    assert "utf8Truncate(warning, 160)" in sanitizer
    assert "local detail = warningDetail(parsed.warnings) or sanitizeWarning(parsed.detail)" in LUA
    assert "local subtitle = joinDetails(detail, hint)" in LUA
    assert 'httpStatus == 401' in LUA
    assert '"请打开句译自动修复本地认证"' in LUA


def test_empty_input_keeps_its_actionable_hint_even_on_http_400():
    callback = _between("local function callTranslate", "-- ---------- engine selection")
    empty_input = callback.index('parsed.error == "empty_input"')
    generic_http_error = callback.index("httpStatus < 200 or httpStatus >= 300")
    assert empty_input < generic_http_error


def test_every_http_call_uses_centralized_optional_bearer_headers():
    assert 'AUTH_TOKEN_PATH = os.getenv("HOME") .. "/.config/argos-translator/auth-token"' in LUA
    assert 'headers["Authorization"] = "Bearer " .. token' in LUA
    assert "if token then" in LUA
    assert '#token ~= 64 or not token:match("^[0-9a-f]+$")' in LUA

    calls = re.findall(r"hs\.http\.(?:asyncGet|asyncPost)\((.*?)\n\s*\)", LUA, re.S)
    assert calls
    for call in calls:
        assert "requestHeaders(" in call


def test_async_engine_refresh_cannot_restore_stale_cloud_choice():
    init = _between("local function initEngineState", "local function startExternalEngineWatcher")
    assert "local persisted = readPersistedEngine()" in init
    assert "if readPersistedEngine() ~= requested then return end" in LUA
