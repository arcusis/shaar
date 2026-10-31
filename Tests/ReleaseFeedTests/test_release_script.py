# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "release.sh"


class ReleaseScriptOptionTests(unittest.TestCase):
    """Unsafe or malformed release requests stop before signing, building or uploading."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="release-script-tests-")
        self.tools = Path(self.temp.name)
        self.notes = self.tools / "notes.html"
        self.notes.write_text("<li>Notes</li>\n")
        for name in ("security", "codesign", "swift", "gh", "xcrun", "curl", "hdiutil"):
            tool = self.tools / name
            tool.write_text("#!/bin/bash\necho \"unexpected $0\" >&2\nexit 97\n")
            tool.chmod(0o755)

    def tearDown(self):
        self.temp.cleanup()

    def _run(self, *args, python=sys.executable):
        environment = os.environ | {"PATH": f"{self.tools}:{os.environ['PATH']}", "PYTHON": python}
        return subprocess.run(
            ["bash", str(SCRIPT), *args], cwd=REPO, env=environment, capture_output=True, text=True
        )

    def test_invalid_or_unsafe_options_fail_before_any_tool_runs(self):
        notes = str(self.notes)
        cases = (
            (),
            ("--notes",),
            ("--unknown", "--notes", notes),
            ("--notes", notes, "--notes", notes),
            ("--notes", notes, "--notarize", "--notarize"),
            ("--notes", notes, "--upload"),
            ("--notes", notes, "--notarize", "--upload", "--allow-unsigned-update"),
        )
        for args in cases:
            with self.subTest(args=args):
                result = self._run(*args)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertNotIn("unexpected", result.stderr)

    def test_missing_notes_file_fails_before_any_tool_runs(self):
        result = self._run("--notes", str(self.tools / "missing.html"))

        self.assertEqual(result.returncode, 1)
        self.assertIn("release notes file is missing", result.stderr)
        self.assertNotIn("unexpected", result.stderr)

    def test_missing_release_python_stops_before_any_tool_runs(self):
        result = self._run("--notes", str(self.notes), python=str(self.tools / "missing-python"))

        self.assertEqual(result.returncode, 1)
        self.assertIn("release-requirements.txt", result.stderr)
        self.assertNotIn("unexpected", result.stderr)

    def test_missing_signing_identity_stops_before_build(self):
        result = self._run("--notes", str(self.notes))

        self.assertEqual(result.returncode, 1)
        self.assertIn("signing identity not found", result.stderr)
        self.assertNotIn("Building engine bundle", result.stdout)


if __name__ == "__main__":
    unittest.main()
