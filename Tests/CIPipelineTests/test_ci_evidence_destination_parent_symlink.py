# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ci_evidence", ROOT / "scripts/ci-evidence.py")
EVIDENCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVIDENCE)


class CIEvidenceDestinationParentSymlinkTests(unittest.TestCase):
    def test_collect_rejects_symlinked_destination_parent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root / "outside"
            outside.mkdir()
            sentinel = outside / "keep.txt"
            sentinel.write_text("preserve this evidence")
            linked_parent = root / "linked-output"
            linked_parent.symlink_to(outside, target_is_directory=True)
            destination = linked_parent / "evidence"

            with tempfile.TemporaryDirectory(prefix="arcusis-engine-probe-") as probe_temp:
                probe = Path(probe_temp)
                (probe / ".arcusis-probe").write_text("arcusis-engine-probe-v1\n")
                (probe / "receipt.json").write_text("{}\n")
                log = root / "probe.log"
                log.write_text(f"Probe evidence: {probe}\n")

                with self.assertRaisesRegex(ValueError, "symlinked parent"):
                    EVIDENCE.collect(log, destination)

            self.assertEqual(sentinel.read_text(), "preserve this evidence")
            self.assertFalse((outside / "evidence").exists())


if __name__ == "__main__":
    unittest.main()
