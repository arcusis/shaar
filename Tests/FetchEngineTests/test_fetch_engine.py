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
        self.third_party = self.root / "ThirdParty/ArdiaCore"
        self.third_party.mkdir(parents=True)
        self.pin_path = self.third_party / "pin.json"
        self.tree = "a1b2c3d4e5f6789012345678901234567890abcd"
        self.key = self.tree[:12]
        self.cache = self.root / "build/EngineCache"
        self.destination = self.cache / self.key
        self.archive = self.cache / f"ArdiaCore-{self.key}.tar.xz"
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.tool_log = self.root / "tool.log"
        self._tool("uname", "printf 'arm64\\n'")
        self._tool("curl", "printf 'curl\\n' >> \"$FETCH_TEST_TOOL_LOG\"; exit 99")
        self.env = os.environ.copy()
        self.env.update(PATH=f"{self.tools}:{self.env['PATH']}", FETCH_TEST_TOOL_LOG=str(self.tool_log))

        self.cache.mkdir(parents=True)
        write_archive(self.archive)
        self.pin = {
            "sourceCommit": "0" * 40,
            "engineTree": self.tree,
            "archiveURL": "https://invalid.example/never-fetched.tar.xz",
            "sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest(),
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


if __name__ == "__main__":
    unittest.main()
