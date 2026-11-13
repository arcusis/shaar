# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("check_release_ci", ROOT / "scripts/check-release-ci.py")
RELEASE_CI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELEASE_CI)


class ReleaseAPIShapeTests(unittest.TestCase):
    def test_malformed_workflow_and_job_api_responses_are_rejected(self):
        revision = "a" * 40
        for response in ({"workflow_runs": None}, {"workflow_runs": [None]}):
            with patch.object(RELEASE_CI, "api", return_value=response):
                with self.assertRaisesRegex(ValueError, "Invalid GitHub API response for source-checks.yml workflow runs"):
                    RELEASE_CI.require_workflow("arcusis/shaar", revision, "source-checks.yml", {"CI required"})
        valid = {"id": 9, "head_sha": revision, "head_branch": "production", "event": "push",
                 "status": "completed", "conclusion": "success"}
        for response in ({"jobs": None}, {"jobs": [None]}):
            with patch.object(RELEASE_CI, "api", side_effect=[{"workflow_runs": [valid]}, response]):
                with self.assertRaisesRegex(ValueError, "Invalid GitHub API response for source-checks.yml run 9 jobs"):
                    RELEASE_CI.require_workflow("arcusis/shaar", revision, "source-checks.yml", {"CI required"})

    def test_invalid_github_api_json_names_the_endpoint(self):
        path = "repos/arcusis/shaar/actions/workflows/source-checks.yml/runs"
        with patch.object(RELEASE_CI.subprocess, "check_output", return_value="{"):
            with self.assertRaisesRegex(ValueError, "GitHub API returned invalid JSON for .*source-checks.yml/runs"):
                RELEASE_CI.api(path)
