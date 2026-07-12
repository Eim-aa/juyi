"""_load_env_file(): the volc.env parser."""
from config import _load_env_file


def test_missing_file_returns_empty(tmp_path):
    assert _load_env_file(tmp_path / "nope.env") == {}


def test_basic_parsing(tmp_path):
    p = tmp_path / "volc.env"
    p.write_text(
        "# comment\n"
        "\n"
        "NOEQUALS\n"
        "A=plain\n"
        "  B  =  spaced  \n"
        "C=a=b\n",
        encoding="utf-8",
    )
    out = _load_env_file(p)
    assert out == {"A": "plain", "B": "spaced", "C": "a=b"}


def test_quoted_values_are_unwrapped(tmp_path):
    p = tmp_path / "volc.env"
    p.write_text(
        'A="abc"\n'
        "B='xyz'\n"
        'D="unmatched\n'
        'E=in"side"quotes\n'
        'F=""\n',
        encoding="utf-8",
    )
    out = _load_env_file(p)
    assert out["A"] == "abc"
    assert out["B"] == "xyz"
    assert out["D"] == '"unmatched'      # unmatched quote left alone
    assert out["E"] == 'in"side"quotes'  # inner quotes left alone
    assert out["F"] == ""
