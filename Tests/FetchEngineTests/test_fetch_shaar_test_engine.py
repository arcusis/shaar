# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import hashlib
import io
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]


class FetchShaarTestEngineTests(unittest.TestCase):
    def test_invalid_cache_roots_are_rejected_before_access(self):
        for relative in ("build", "build/ShaarEngineTestCache"):
            for kind in ("symlink", "file"):
                with self.subTest(path=relative, kind=kind), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    scripts = root / "scripts"
                    scripts.mkdir()
                    shutil.copy2(REPO / "scripts/fetch-shaar-test-engine.sh", scripts)
                    external = root / "external"
                    external.mkdir()
                    sentinel = external / "keep.txt"
                    sentinel.write_text("leave untouched")
                    link = root / relative
                    if relative != "build":
                        link.parent.mkdir()
                    if kind == "symlink":
                        link.symlink_to(external, target_is_directory=True)
                    else:
                        link.write_text("not a directory")
                    tools = root / "tools"
                    tools.mkdir()
                    uname = tools / "uname"
                    uname.write_text("#!/bin/sh\nprintf 'arm64\\n'\n")
                    uname.chmod(0o755)
                    environment = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}")

                    result = subprocess.run(
                        ["bash", str(scripts / "fetch-shaar-test-engine.sh")],
                        cwd=root, env=environment, capture_output=True, text=True,
                    )

                    self.assertNotEqual(result.returncode, 0)
                    expected = "must not be a symlink" if kind == "symlink" else "must be a directory"
                    self.assertIn(expected, result.stderr)
                    self.assertEqual(list(external.iterdir()), [sentinel])

    def test_failed_framework_extraction_removes_staging_directory(self):
        with tempfile.TemporaryDirectory(prefix="fetch-shaar-test-engine-") as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            scripts.mkdir()
            shutil.copy2(REPO / "scripts/fetch-shaar-test-engine.sh", scripts)
            shutil.copy2(REPO / "scripts/engine_payload.py", scripts)
            pin_path = root / "ThirdParty/ChromiumEngine/ci-test-pin.json"
            pin_path.parent.mkdir(parents=True)
            cache = root / "build/ShaarEngineTestCache"
            cache.mkdir(parents=True)
            tag = "engine-155.0.8059.84-shaar.1"
            asset = "ShaarEngine-155.0.8059.84-shaar.1.tar.xz"
            archive_path = cache / asset
            with tarfile.open(archive_path, "w:xz", format=tarfile.PAX_FORMAT) as archive:
                info = tarfile.TarInfo("unrelated.txt")
                info.size = 7
                archive.addfile(info, io.BytesIO(b"invalid"))
            pin_path.write_text(json.dumps({
                "schemaVersion": 1,
                "sourceKind": "shaar",
                "releaseTag": tag,
                "asset": asset,
                "sha256": hashlib.sha256(archive_path.read_bytes()).hexdigest(),
            }))
            tools = root / "tools"
            tools.mkdir()
            uname = tools / "uname"
            uname.write_text("#!/bin/sh\nprintf 'arm64\\n'\n")
            uname.chmod(0o755)
            environment = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}")

            result = subprocess.run(
                ["bash", str(scripts / "fetch-shaar-test-engine.sh")],
                cwd=root, env=environment, capture_output=True, text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Shaar test framework missing", result.stderr)
            self.assertEqual(list(cache.glob("stage.*")), [])


if __name__ == "__main__":
    unittest.main()
