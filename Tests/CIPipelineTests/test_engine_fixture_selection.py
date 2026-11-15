# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "engine_fixture", ROOT / "scripts/engine_fixture.py")
FIXTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURE)


class EngineFixtureSelectionTests(unittest.TestCase):
    def test_library_and_store_probes_have_independent_modes(self):
        library = FIXTURE.argument_parser().parse_args(["--library-only"])
        bitwarden = FIXTURE.argument_parser().parse_args(["--bitwarden-only"])
        self.assertTrue(library.library_only)
        self.assertTrue(bitwarden.bitwarden_only)

    def test_selected_modes_reach_the_matching_verification_entrypoint(self):
        shared = dict(
            onboarding_control=False, abrupt=False, saved_tab_capacity=False)
        library = FIXTURE.build_engine_probe_arguments(
            Path("/tmp/ShaarVerification"), Path("/tmp/probe"), "http://127.0.0.1:1234/account",
            "initial", include_bitwarden=False, library_only=True, **shared)
        self.assertIn("--probe-library-only", library)
        self.assertNotIn("--bitwarden", library)

        store = FIXTURE.build_engine_probe_arguments(
            Path("/tmp/ShaarVerification"), Path("/tmp/probe"), "http://127.0.0.1:1234/account",
            "initial", include_bitwarden=True, bitwarden_only=True, **shared)
        self.assertIn("--probe-bitwarden-only", store)
        self.assertNotIn("--bitwarden", store)

    def test_proof_runner_accepts_import_store_and_permission_probe_ids(self):
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/v02-proof-run.sh"), "/missing/archive.tar.xz",
             "--probes", "5,6,9,15"], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("Engine archive must be a regular", result.stderr)
        self.assertNotIn("Usage:", result.stderr)


if __name__ == "__main__":
    unittest.main()
