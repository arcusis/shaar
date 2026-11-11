# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import hashlib
import json
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/engine_patches.py"


class EnginePatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.src = self.root / "src"
        self.src.mkdir()
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.test")
        self.git("config", "user.name", "Test")
        (self.src / "a.txt").write_text("one\n")
        (self.src / "b.txt").write_text("first\n")
        self.git("add", ".")
        self.git("-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                 "commit", "-qm", "base")
        self.revision = self.git("rev-parse", "HEAD").stdout.strip()
        patches = self.root / "ThirdParty/ChromiumEngine/patches"
        patches.mkdir(parents=True)
        self.manifest = patches.parent / "source-build.json"
        entries = []
        for number, filename, old, new in ((1, "a.txt", "one", "two"),
                                            (2, "b.txt", "first", "second")):
            (self.src / filename).write_text(new + "\n")
            diff = self.git("diff", "--", filename).stdout.encode()
            (self.src / filename).write_text(old + "\n")
            path = patches / f"{number:04d}-test.patch"
            path.write_bytes(diff)
            entries.append({"file": str(path.relative_to(self.root)),
                            "sha256": hashlib.sha256(diff).hexdigest()})
        self.entries = entries
        self.manifest.write_text(json.dumps({"chromium": {"commit": self.revision}, "patches": entries}))
        self.output = self.root / "build/applied-patches.json"

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.src), *args], capture_output=True,
                              text=True, check=True)

    def run_script(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), "--manifest", str(self.manifest),
                               *map(str, args)], capture_output=True, text=True)

    def test_applies_full_series_and_writes_receipt(self):
        result = self.run_script("--apply", self.src, "--output", self.output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.src / "a.txt").read_text(), "two\n")
        self.assertEqual((self.src / "b.txt").read_text(), "second\n")
        self.assertEqual(json.loads(self.output.read_text()), {"schemaVersion": 1,
                         "chromiumRevision": self.revision, "patches": self.entries})

    def test_dirty_or_wrong_revision_refused(self):
        (self.src / "untracked").write_text("dirty")
        self.assertNotEqual(self.run_script("--apply", self.src, "--output", self.output).returncode, 0)
        self.assertFalse(self.output.exists())
        (self.src / "untracked").unlink()
        data = json.loads(self.manifest.read_text())
        data["chromium"]["commit"] = "f" * 40
        self.manifest.write_text(json.dumps(data))
        self.assertNotEqual(self.run_script("--apply", self.src, "--output", self.output).returncode, 0)

    def test_failed_patch_leaves_no_receipt(self):
        path = self.root / self.entries[1]["file"]
        data = path.read_bytes().replace(b"-first", b"-absent")
        path.write_bytes(data)
        self.entries[1]["sha256"] = hashlib.sha256(data).hexdigest()
        self.manifest.write_text(json.dumps({"chromium": {"commit": self.revision}, "patches": self.entries}))
        self.output.parent.mkdir()
        self.output.write_text("stale")
        result = self.run_script("--apply", self.src, "--output", self.output)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())
        self.assertEqual((self.src / "a.txt").read_text(), "two\n")

    def test_archive_receipt_requires_complete_ordered_series(self):
        self.assertEqual(self.run_script("--apply", self.src, "--output", self.output).returncode, 0)
        archive = self.root / "engine.tar.xz"
        for entries, passes in ((self.entries, True), (self.entries[:1], False),
                                (list(reversed(self.entries)), False)):
            receipt = {"schemaVersion": 1, "chromiumRevision": self.revision, "patches": entries}
            self.output.write_text(json.dumps(receipt))
            with tarfile.open(archive, "w:xz") as tar:
                tar.add(self.output, arcname="applied-patches.json")
            result = self.run_script("--verify-archive", archive)
            self.assertEqual(result.returncode == 0, passes, result.stderr)


if __name__ == "__main__":
    unittest.main()
