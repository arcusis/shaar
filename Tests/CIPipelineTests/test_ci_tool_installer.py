# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from contextlib import redirect_stderr
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("install_ci_tools", ROOT / "scripts/install-ci-tools.py")
INSTALLER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALLER)


class CIToolInstallerTests(unittest.TestCase):
    def assert_install_rejected(self, destination, message):
        manifest = {"tool": {"Darwin-arm64": {"url": "https://example.invalid/tool",
                                                "sha256": "a" * 64}}}
        errors = io.StringIO()
        with (patch.object(INSTALLER.json, "loads", return_value=manifest),
              patch.object(INSTALLER.platform, "system", return_value="Darwin"),
              patch.object(INSTALLER.platform, "machine", return_value="arm64"),
              patch.object(INSTALLER, "archive_payload") as download,
              patch.object(sys, "argv", ["install-ci-tools.py", "--destination", str(destination)]),
              redirect_stderr(errors)):
            with self.assertRaises(SystemExit) as caught:
                INSTALLER.main()

        self.assertEqual(caught.exception.code, 2)
        self.assertIn(message, errors.getvalue())
        download.assert_not_called()

    def test_symlinked_tool_output_is_rejected_before_fetching(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            root = Path(directory)
            destination = root / "tools"
            destination.mkdir()
            sentinel = Path(outside) / "sentinel"
            sentinel.write_text("preserve", encoding="utf-8")
            (destination / "tool").symlink_to(sentinel)

            self.assert_install_rejected(destination, "Refusing symlinked CI tool output")

            self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve")

    def test_symlinked_destination_directory_is_rejected_before_fetching(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            destination = Path(directory) / "tools"
            external = Path(outside)
            sentinel = external / "sentinel"
            sentinel.write_text("preserve", encoding="utf-8")
            destination.symlink_to(external, target_is_directory=True)

            self.assert_install_rejected(destination, "Refusing symlinked CI tool destination directory")

            self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve")

    def test_symlinked_destination_parent_is_rejected_before_fetching(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            destination = Path(directory) / "linked" / "tools"
            external = Path(outside)
            sentinel = external / "sentinel"
            sentinel.write_text("preserve", encoding="utf-8")
            destination.parent.symlink_to(external, target_is_directory=True)

            self.assert_install_rejected(destination, "Refusing symlinked CI tool destination parent")

            self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve")


if __name__ == "__main__":
    unittest.main()
