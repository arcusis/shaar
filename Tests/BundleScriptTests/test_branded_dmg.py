# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]


class BrandedDMGTests(unittest.TestCase):
    def test_dangling_output_symlink_is_rejected_before_dmg_tools_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            scripts.mkdir()
            shutil.copy2(REPO / "scripts/create-branded-dmg.sh", scripts)
            resources = root / "Resources"
            for directory in ("Installer", "Branding"):
                (resources / directory).mkdir(parents=True)
            for name in ("background.png", ".DS_Store"):
                (resources / "Installer" / name).write_bytes(b"fixture")
            (resources / "Branding/Shaar.icns").write_bytes(b"fixture")
            app = root / "Shaar.app"
            (app / "Contents").mkdir(parents=True)

            tools = root / "tools"
            tools.mkdir()
            log = root / "tool.log"
            hdiutil = tools / "hdiutil"
            hdiutil.write_text(
                "#!/bin/bash\n"
                "printf '%s\\n' \"$*\" >> \"$DMG_TEST_LOG\"\n"
                "if [[ $1 == convert ]]; then\n"
                "  while (($#)); do\n"
                "    if [[ $1 == -o ]]; then shift; : > \"$1\"; break; fi\n"
                "    shift\n"
                "  done\n"
                "fi\n"
            )
            hdiutil.chmod(0o755)
            ditto = tools / "ditto"
            ditto.write_text("#!/bin/bash\n/bin/cp -R \"$1\" \"$2\"\n")
            ditto.chmod(0o755)
            xcrun = tools / "xcrun"
            xcrun.write_text("#!/bin/bash\nexit 0\n")
            xcrun.chmod(0o755)

            output = root / "Shaar.dmg"
            target = root / "outside.dmg"
            output.symlink_to(target)
            env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}", DMG_TEST_LOG=str(log))
            result = subprocess.run(
                ["bash", str(scripts / "create-branded-dmg.sh"), str(app), str(output)],
                cwd=root, env=env, capture_output=True, text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Output must not be a symlink", result.stderr)
            self.assertFalse(target.exists())
            self.assertFalse(log.exists())


if __name__ == "__main__":
    unittest.main()
