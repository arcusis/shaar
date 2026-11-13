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
FRAMEWORK = "Chromium Framework.framework"


def write_archive(path):
    with tarfile.open(path, "w:xz", format=tarfile.PAX_FORMAT) as archive:
        files = {
            f"{FRAMEWORK}/Versions/A/Chromium Framework": b"engine binary bytes",
            f"{FRAMEWORK}/Resources/helper.dat": b"pinned resource",
        }
        for directory in (
            FRAMEWORK,
            f"{FRAMEWORK}/Versions",
            f"{FRAMEWORK}/Versions/A",
            f"{FRAMEWORK}/Resources",
        ):
            info = tarfile.TarInfo(directory)
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            archive.addfile(info)
        for name, data in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
        link = tarfile.TarInfo(f"{FRAMEWORK}/Versions/Current")
        link.type = tarfile.SYMTYPE
        link.linkname = "A"
        archive.addfile(link)


class FetchEngineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fetch-engine-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()
        shutil.copy2(REPO / "scripts/fetch-engine.sh", self.scripts / "fetch-engine.sh")
        shutil.copy2(REPO / "scripts/engine_payload.py", self.scripts / "engine_payload.py")
        self.third_party = self.root / "ThirdParty/ChromiumEngine"
        self.third_party.mkdir(parents=True)
        self.pin_path = self.third_party / "pin.json"
        self.cache = self.root / "build/EngineCache"
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.tool_log = self.root / "tool.log"
        self._tool("uname", "printf 'arm64\\n'")
        self._tool("curl", "printf 'curl\\n' >> \"$FETCH_TEST_TOOL_LOG\"; exit 99")
        self.env = os.environ.copy()
        self.env.update(PATH=f"{self.tools}:{self.env['PATH']}", FETCH_TEST_TOOL_LOG=str(self.tool_log))

        self.cache.mkdir(parents=True)
        staged = self.root / "staged.tar.xz"
        write_archive(staged)
        checksum = hashlib.sha256(staged.read_bytes()).hexdigest()
        self.destination = self.cache / checksum[:16]
        self.archive = self.cache / "ShaarEngine-157.0.8103.51-shaar.4.tar.xz"
        staged.rename(self.archive)
        self.pin = {
            "schemaVersion": 1,
            "sourceKind": "shaar",
            "releaseTag": "engine-157.0.8103.51-shaar.4",
            "asset": self.archive.name,
            "sha256": checksum,
        }
        self._write_pin()
        self._extract_fixture()

    def _tool(self, name, body):
        path = self.tools / name
        path.write_text("#!/bin/bash\nset -euo pipefail\n" + body + "\n")
        path.chmod(0o755)

    def _write_pin(self):
        self.pin_path.write_text(json.dumps(self.pin))

    def _extract_fixture(self):
        self.destination.mkdir(parents=True, exist_ok=True)
        with tarfile.open(self.archive, "r:xz") as archive:
            archive.extractall(self.destination)
        (self.destination / f".verified-{self.pin['sha256']}").touch()

    def _run(self):
        return subprocess.run(
            ["bash", str(self.scripts / "fetch-engine.sh")],
            cwd=self.root,
            env=self.env,
            capture_output=True,
            text=True,
        )

    @property
    def framework(self):
        return self.destination / FRAMEWORK

    def test_intact_cached_marker_returns_only_framework_path(self):
        result = self._run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"{self.framework}\n")
        self.assertEqual(self.tool_log.read_text() if self.tool_log.exists() else "", "")

    def test_build_and_engine_cache_roots_reject_symlinks_and_non_directories(self):
        cases = (
            ("build", "symlink", "must not be a symlink"),
            ("build/EngineCache", "symlink", "must not be a symlink"),
            ("build", "file", "must be a directory"),
            ("build/EngineCache", "file", "must be a directory"),
        )
        build_root = self.root / "build"
        for relative, kind, message in cases:
            with self.subTest(path=relative, kind=kind):
                if build_root.is_symlink() or build_root.is_file():
                    build_root.unlink()
                elif build_root.exists():
                    shutil.rmtree(build_root)

                external = self.root / f"external-{relative.replace('/', '-')}-{kind}"
                external.mkdir()
                sentinel = external / "keep.txt"
                sentinel.write_text("preserve this cache")
                path = self.root / relative
                if relative == "build/EngineCache":
                    path.parent.mkdir()
                if kind == "symlink":
                    path.symlink_to(external, target_is_directory=True)
                else:
                    path.write_text("not a directory")
                self.tool_log.unlink(missing_ok=True)

                result = self._run()

                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn(message, result.stderr)
                self.assertEqual(self.tool_log.read_text() if self.tool_log.exists() else "", "")
                self.assertEqual(sentinel.read_text(), "preserve this cache")
                self.assertEqual(list(external.iterdir()), [sentinel])

    def test_changed_missing_and_extra_cached_members_fail_before_path_return(self):
        cases = (
            ("changed", lambda: (self.framework / "Resources/helper.dat").write_bytes(b"changed")),
            ("missing", lambda: (self.framework / "Resources/helper.dat").unlink()),
            ("extra", lambda: (self.framework / "extra.dat").write_bytes(b"extra")),
        )
        for name, mutate in cases:
            with self.subTest(member=name):
                shutil.rmtree(self.destination)
                self._extract_fixture()
                self.tool_log.unlink(missing_ok=True)
                mutate()
                result = self._run()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("Engine payload verification failed", result.stderr)
                self.assertEqual(self.tool_log.read_text() if self.tool_log.exists() else "", "")

    def test_malformed_pin_fails_closed_without_fetch_or_path_output(self):
        self.pin_path.write_text("{")

        result = self._run()

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.tool_log.read_text() if self.tool_log.exists() else "", "")

    def test_failed_framework_extraction_removes_staging_directory(self):
        shutil.rmtree(self.destination)
        with tarfile.open(self.archive, "w:xz", format=tarfile.PAX_FORMAT) as archive:
            info = tarfile.TarInfo("unrelated.txt")
            info.size = 7
            archive.addfile(info, io.BytesIO(b"invalid"))
        self.pin["sha256"] = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self._write_pin()

        result = self._run()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Engine framework missing", result.stderr)
        self.assertEqual(list(self.cache.glob("stage.*")), [])

    def test_symlinked_engine_cache_root_is_rejected_before_extraction(self):
        shutil.rmtree(self.destination)
        external = self.root / "external-cache"
        self.cache.rename(external)
        self.cache.symlink_to(external, target_is_directory=True)

        result = self._run()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Engine cache path is not a regular directory", result.stderr)
        self.assertFalse((external / self.destination.name).exists())

    def test_symlinked_build_root_is_rejected_before_extraction(self):
        shutil.rmtree(self.destination)
        external = self.root / "external-build"
        (self.root / "build").rename(external)
        (self.root / "build").symlink_to(external, target_is_directory=True)

        result = self._run()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Engine build path is not a regular directory", result.stderr)
        self.assertFalse((external / "EngineCache" / self.destination.name).exists())


if __name__ == "__main__":
    unittest.main()
