"""Make the repo root importable so tests can import the flat modules."""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

# Isolate every import-time HOME lookup before the project modules are loaded.
# Keep the TemporaryDirectory object alive for the entire pytest process.
_test_home = tempfile.TemporaryDirectory(prefix="juyi-pytest-home-")
os.environ["HOME"] = _test_home.name

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


# Importing config.py loads the production credential source. During tests,
# intercept only the exact Keychain lookup so collection can never inspect or
# prompt for a real user's item. Individual Keychain parser tests inject their
# own runner directly.
_subprocess_run = subprocess.run


def _run_without_real_keychain(args, *positional, **kwargs):
    if (
        isinstance(args, (list, tuple))
        and len(args) >= 2
        and args[0] == "/usr/bin/security"
        and args[1] == "find-generic-password"
    ):
        return subprocess.CompletedProcess(args, 44, stdout="")
    return _subprocess_run(args, *positional, **kwargs)


subprocess.run = _run_without_real_keychain
