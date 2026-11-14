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

    def _run(self, *args, python=sys.executable, env=None):
        environment = os.environ | {"PATH": f"{self.tools}:{os.environ['PATH']}", "PYTHON": python}
        environment.pop("SHAAR_MOCK_KEYCHAIN", None)
        if env:
            environment.update(env)
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

    def test_mock_keychain_is_refused_before_any_tool_runs(self):
        result = self._run("--notes", str(self.notes), env={"SHAAR_MOCK_KEYCHAIN": "1"})

        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("SHAAR_MOCK_KEYCHAIN", result.stderr)
        self.assertIn("login keychain", result.stderr)
        self.assertNotIn("unexpected", result.stderr)
        self.assertNotIn("Building", result.stdout)

    def test_built_release_plist_guard_precedes_signing(self):
        source = SCRIPT.read_text()
        guard = 'grep -q \'<key>ShaarUseMockKeychain</key>\' "$app/Contents/Info.plist"'
        self.assertIn(guard, source)
        self.assertLess(source.index(guard), source.index('sign() {'))

    def test_every_release_signing_path_enables_and_verifies_hardened_runtime(self):
        source = SCRIPT.read_text()

        self.assertIn(
            'sign() { codesign --force --options runtime --timestamp '
            '--sign "$sign_identity" "$@"; }',
            source,
        )
        self.assertIn(
            "echo '==> Signing nested code inside out (Developer ID + hardened runtime)'", source
        )
        self.assertIn(
            'echo "==> Asserting team $team_id and hardened runtime on all bundled code"', source
        )
        self.assertIn("grep -Eq 'flags=0x[0-9a-f]+\\([^)]*runtime'", source)
        self.assertIn("((unsigned == 0)) ||", source)

    def test_nested_helpers_keep_only_their_upstream_entitlements(self):
        source = SCRIPT.read_text()
        helper_signing = source[
            source.index("sign_like_upstream() {") :
            source.index("echo '==> Signing nested code inside out")
        ]

        self.assertIn(
            'codesign -d --entitlements - --xml "$upstream" > "$entitlements"',
            helper_signing,
        )
        self.assertIn('sign --entitlements "$entitlements" "$target"', helper_signing)
        self.assertIn('if [[ -s "$entitlements" ]]', helper_signing)
        self.assertIn('sign "$target"', helper_signing)
        self.assertNotIn("app_entitlements", helper_signing)

    def test_missing_signing_identity_stops_before_build(self):
        result = self._run("--notes", str(self.notes))

        self.assertEqual(result.returncode, 1)
        self.assertIn("signing identity not found", result.stderr)
        self.assertNotIn("Building engine bundle", result.stdout)


if __name__ == "__main__":
    unittest.main()
