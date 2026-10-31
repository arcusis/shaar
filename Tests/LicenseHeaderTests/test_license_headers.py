# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


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

    def test_skips_third_party_and_other_file_types(self):
        missing = self._missing({
            "ThirdParty/Vendor/vendor.swift": "import Foundation\n",
            "Resources/manager.html": "<html></html>\n",
        })
        self.assertEqual(missing, [])


if __name__ == "__main__":
    unittest.main()
