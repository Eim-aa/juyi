"""Input normalization, truncation, and language-gate helpers."""
import config
from translator import _cjk_ratio, _letter_count, normalize_input, truncate_input


# ---- normalize_input ----

def test_normalize_none_becomes_empty():
    assert normalize_input(None) == ""


def test_normalize_unifies_line_endings():
    assert normalize_input("a\r\nb\rc\nd") == "a\nb\nc\nd"


def test_normalize_strips_surrounding_whitespace():
    assert normalize_input("  x \n") == "x"
    assert normalize_input(" \r\n ") == ""


# ---- truncate_input ----

def test_no_truncation_at_exact_limit():
    text = "a" * config.MAX_INPUT_CHARS
    assert truncate_input(text) == (text, False)


def test_truncation_one_past_limit():
    text = "a" * (config.MAX_INPUT_CHARS + 1)
    out, truncated = truncate_input(text)
    assert truncated is True
    assert len(out) == config.MAX_INPUT_CHARS
    assert "truncated" not in out  # metadata only, never a marker in the body


def test_truncation_explicit_limit():
    assert truncate_input("abcdef", limit=3) == ("abc", True)
    assert truncate_input("abc", limit=3) == ("abc", False)


# ---- _cjk_ratio (gate: ratio > config.CJK_THRESHOLD means "not English") ----

def test_cjk_ratio_pure_english_is_zero():
    assert _cjk_ratio("Hello world.") == 0.0


def test_cjk_ratio_pure_chinese_is_one():
    assert _cjk_ratio("你好世界") == 1.0


def test_cjk_ratio_ignores_whitespace():
    assert _cjk_ratio("你 好\n世 界") == 1.0


def test_cjk_ratio_at_threshold_passes_gate():
    # Exactly 0.5 is NOT > CJK_THRESHOLD: still treated as translatable.
    assert _cjk_ratio("ab你好") == 0.5
    assert not (_cjk_ratio("ab你好") > config.CJK_THRESHOLD)


def test_cjk_ratio_above_threshold_trips_gate():
    assert _cjk_ratio("a你好") > config.CJK_THRESHOLD


def test_cjk_ratio_empty_is_zero():
    assert _cjk_ratio("") == 0.0
    assert _cjk_ratio("   ") == 0.0


# ---- _letter_count (gate: < 2 letters is skipped) ----

def test_letter_count_punctuation_only():
    assert _letter_count("...!!!") == 0


def test_letter_count_basic():
    assert _letter_count("A") == 1
    assert _letter_count("ab") == 2
    assert _letter_count("a1b2") == 2


def test_letter_count_counts_cjk_as_letters():
    # str.isalpha() is true for CJK; harmless because the CJK gate runs first.
    assert _letter_count("你好") == 2
