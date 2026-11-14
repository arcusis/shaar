# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("ci_stage", ROOT / "scripts/ci-stage.py")
STAGES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STAGES)


class CIGitHubOutputSymlinkTests(unittest.TestCase):
    def test_engine_bundle_paths_reject_symlinked_github_output(self):
        from ci_support import Commands

        for reuse in (False, True):
            with self.subTest(reuse=reuse), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                output = root / "github-output"
                external = root / "external.txt"
                external.write_text("preserve this output")
                output.symlink_to(external)

                with patch("ci_support.ROOT", root), patch.object(STAGES, "ROOT", root), \
                        patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}):
                    checks = Commands("engine-build")
                    if reuse:
                        (checks.directory / "bundle.json").write_text("{}")
                    with patch.object(STAGES, "require_hosted_mac"), \
                            patch.object(STAGES, "engine_shards", return_value=["baseline-1"]), \
                            patch.object(STAGES, "validate_bundle_archive"), \
                            patch.object(STAGES, "archive_bundle"), \
                            patch.object(checks, "run", return_value=0):
                        with self.assertRaisesRegex(
                            ValueError, "CI evidence output must not be a symlink"
                        ):
                            STAGES.build_engine_bundle(checks, 1)

                self.assertEqual(external.read_text(), "preserve this output")


if __name__ == "__main__":
    unittest.main()
