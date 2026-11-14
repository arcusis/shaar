# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("check_license_headers", REPO / "scripts" / "check-license-headers.py")
check_license_headers = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = check_license_headers
SPEC.loader.exec_module(check_license_headers)

SWIFT_NOTICE = "\n".join(check_license_headers.expected_notice(Path("File.swift")))
SHELL_NOTICE = "\n".join(check_license_headers.expected_notice(Path("script.sh")))


class LicenseHeaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="license-header-tests-")
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def _missing(self, files):
        for name, text in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        return check_license_headers.files_missing_notice(self.root, [Path(name) for name in files])

    def test_repository_sources_carry_notice(self):
        tracked = check_license_headers.tracked_files(REPO)
        self.assertEqual(check_license_headers.files_missing_notice(REPO, tracked), [])

    def test_accepts_notice_after_preamble_line(self):
        missing = self._missing({
            "Package.swift": f"// swift-tools-version: 6.2\n{SWIFT_NOTICE}\n",
            "run.sh": f"#!/bin/bash\n{SHELL_NOTICE}\n",
            "Sources/View.swift": f"{SWIFT_NOTICE}\n\nimport SwiftUI\n",
        })
        self.assertEqual(missing, [])

    def test_reports_missing_or_displaced_notice(self):
        missing = self._missing({
            "Sources/Bare.swift": "import Foundation\n",
            "Sources/Late.swift": f"import Foundation\n{SWIFT_NOTICE}\n",
            "tool.py": f"{SWIFT_NOTICE}\n",
        })
        self.assertEqual(missing, [Path("Sources/Bare.swift"), Path("Sources/Late.swift"), Path("tool.py")])

    def test_tracked_symlink_does_not_inherit_target_license_header(self):
        external = self.root / "outside.py"
        external.write_text("\n".join(check_license_headers.expected_notice(Path("outside.py"))) + "\n",
                            encoding="utf-8")
        (self.root / "linked.py").symlink_to(external)
        self.assertEqual(check_license_headers.files_missing_notice(self.root, [Path("linked.py")]),
                         [Path("linked.py")])

    def test_invalid_utf8_tracked_source_is_reported_as_missing_notice(self):
        (self.root / "broken.py").write_bytes(b"# invalid: \xff\n")
        self.assertEqual(
            check_license_headers.files_missing_notice(self.root, [Path("broken.py")]),
            [Path("broken.py")],
        )

    def test_unreadable_source_reports_a_direct_error(self):
        path = self.root / "invalid.py"
        path.write_bytes(b"\xff\xfe")
        with self.assertRaisesRegex(ValueError, "cannot read tracked source for license header check: invalid.py"):
            check_license_headers.files_missing_notice(self.root, [Path("invalid.py")])

    def test_skips_third_party_and_other_file_types(self):
        missing = self._missing({
            "ThirdParty/Vendor/vendor.swift": "import Foundation\n",
            "Resources/manager.html": "<html></html>\n",
        })
        self.assertEqual(missing, [])

    def test_website_source_headers(self):
        files = ["website/src/client.ts", "website/wrangler.jsonc", "website/src/styles.css", "website/public/social.svg"]
        valid = {name: "\n".join(check_license_headers.expected_notice(Path(name))) + "\n" for name in files}
        self.assertEqual(self._missing(valid), [])
        self.assertEqual(self._missing({name: "no header\n" for name in files}), [Path(name) for name in files])

    def test_tracked_file_names_use_filesystem_surrogate_escapes(self):
        raw_name = b"source-\xff.py"
        completed = type("Completed", (), {"stdout": raw_name + b"\0"})()
        with patch.object(check_license_headers.subprocess, "run", return_value=completed):
            paths = check_license_headers.tracked_files(self.root)
        self.assertEqual(paths, [Path(os.fsdecode(raw_name))])

    def test_unreadable_tracked_file_reports_its_path_without_traceback(self):
        source = self.root / "broken.py"
        source.write_bytes(b"\xff")
        errors = io.StringIO()
        with (patch.object(check_license_headers, "REPOSITORY_ROOT", self.root),
              patch.object(check_license_headers, "tracked_files", return_value=[Path("broken.py")]),
              patch("sys.stderr", errors)):
            self.assertEqual(check_license_headers.main(), 1)
        self.assertIn("Cannot read tracked file for MPL-2.0 header check: broken.py", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
