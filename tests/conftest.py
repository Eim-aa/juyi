"""Shared pytest setup. Every test is a static contract over repository files.

HOME is isolated for the whole session so no test can read or touch the real
user's configuration, Hammerspoon or LaunchAgents directories.
"""
import os
import tempfile

# Keep the TemporaryDirectory object alive for the entire pytest process.
_test_home = tempfile.TemporaryDirectory(prefix="juyi-pytest-home-")
os.environ["HOME"] = _test_home.name
