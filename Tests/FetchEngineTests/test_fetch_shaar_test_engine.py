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

    def test_symlinked_archive_cache_is_rejected_before_gh_download(self):
        with tempfile.TemporaryDirectory(prefix="fetch-shaar-test-engine-") as temporary, \
                tempfile.TemporaryDirectory() as outside:
            root = Path(temporary)
            scripts = root / "scripts"
            scripts.mkdir()
            shutil.copy2(REPO / "scripts/fetch-shaar-test-engine.sh", scripts)
            cache = root / "build/ShaarEngineTestCache"
            cache.mkdir(parents=True)
            tag = "engine-155.0.8059.84-shaar.1"
            asset = "ShaarEngine-155.0.8059.84-shaar.1.tar.xz"
            archive_path = cache / asset
            sentinel = Path(outside) / "preserve.txt"
            sentinel.write_text("preserve")
            archive_path.symlink_to(sentinel)
            pin_path = root / "ThirdParty/ChromiumEngine/ci-test-pin.json"
            pin_path.parent.mkdir(parents=True)
            payload = b"pinned archive"
            pin_path.write_text(json.dumps({
                "schemaVersion": 1,
                "sourceKind": "shaar",
                "releaseTag": tag,
                "asset": asset,
                "sha256": hashlib.sha256(payload).hexdigest(),
            }))
            tools = root / "tools"
            tools.mkdir()
            uname = tools / "uname"
            uname.write_text("#!/bin/sh\nprintf 'arm64\\n'\n")
            uname.chmod(0o755)
            gh_log = root / "gh.log"
            gh = tools / "gh"
            gh.write_text('''#!/bin/bash
set -euo pipefail
printf 'called\\n' >> "$FETCH_TEST_GH_LOG"
while (($#)); do
  case "$1" in
    --pattern) asset="$2"; shift 2 ;;
    --dir) directory="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'downloaded' > "$directory/$asset"
''')
            gh.chmod(0o755)
            environment = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                               FETCH_TEST_GH_LOG=str(gh_log))

            result = subprocess.run(
                ["bash", str(scripts / "fetch-shaar-test-engine.sh")],
                cwd=root, env=environment, capture_output=True, text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Shaar test archive cache path must not be a symlink", result.stderr)
            self.assertEqual(sentinel.read_text(), "preserve")
            self.assertFalse(gh_log.exists())

    def _fixture(self, root):
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
        return cache, environment

    def test_failed_framework_extraction_removes_staging_directory(self):
        with tempfile.TemporaryDirectory(prefix="fetch-shaar-test-engine-") as temporary:
            root = Path(temporary)
            cache, environment = self._fixture(root)
            result = subprocess.run(
                ["bash", str(root / "scripts/fetch-shaar-test-engine.sh")],
                cwd=root, env=environment, capture_output=True, text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Shaar test framework missing", result.stderr)
            self.assertEqual(list(cache.glob("stage.*")), [])

    def test_symlinked_cache_root_is_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory(prefix="fetch-shaar-test-engine-") as temporary:
            root = Path(temporary)
            cache, environment = self._fixture(root)
            external = root / "external-cache"
            cache.rename(external)
            cache.symlink_to(external, target_is_directory=True)

            result = subprocess.run(
                ["bash", str(root / "scripts/fetch-shaar-test-engine.sh")],
                cwd=root, env=environment, capture_output=True, text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Shaar test engine cache root must not be a symlink", result.stderr)
            self.assertEqual(list(external.glob("stage.*")), [])

    def test_symlinked_build_root_is_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory(prefix="fetch-shaar-test-engine-") as temporary:
            root = Path(temporary)
            self._fixture(root)
            build = root / "build"
            external = root / "external-build"
            build.rename(external)
            build.symlink_to(external, target_is_directory=True)

            result = subprocess.run(
                ["bash", str(root / "scripts/fetch-shaar-test-engine.sh")],
                cwd=root, env=dict(os.environ, PATH=f"{root / 'tools'}:{os.environ['PATH']}"),
                capture_output=True, text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Shaar test engine cache root must not be a symlink", result.stderr)


if __name__ == "__main__":
    unittest.main()
