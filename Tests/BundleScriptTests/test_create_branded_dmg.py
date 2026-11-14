# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]


class BrandedDMGTests(unittest.TestCase):
    def test_dangling_output_symlink_is_rejected_before_tools_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "Shaar.app"
            (app / "Contents").mkdir(parents=True)
            output_target = root / "outside.dmg"
            output = root / "Shaar.dmg"
            output.symlink_to(output_target)
            tools = root / "tools"
            tools.mkdir()
            log = root / "tool.log"
            ditto = tools / "ditto"
            ditto.write_text('#!/bin/sh\nprintf called >> "$DMG_TOOL_LOG"\nexit 1\n')
            ditto.chmod(0o755)
            environment = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}", DMG_TOOL_LOG=str(log))

            result = subprocess.run(
                ["bash", str(REPO / "scripts/create-branded-dmg.sh"), str(app), str(output)],
                cwd=REPO, env=environment, capture_output=True, text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Output already exists", result.stderr)
            self.assertFalse(log.exists())
            self.assertTrue(output.is_symlink())
            self.assertFalse(output_target.exists())


if __name__ == "__main__":
    unittest.main()
