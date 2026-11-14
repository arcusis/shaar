# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from contextlib import redirect_stderr
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ci_plan", ROOT / "scripts/ci-plan.py")
PLAN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PLAN)


class CIPlanEventTests(unittest.TestCase):
    def test_event_loader_requires_a_json_object(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "event.json"
            path.write_text(json.dumps({"pull_request": {"draft": False}}), encoding="utf-8")
            self.assertEqual(PLAN.load_event(path), {"pull_request": {"draft": False}})
            for contents in ("{", "[]", "null"):
                with self.subTest(contents=contents):
                    path.write_text(contents, encoding="utf-8")
                    with self.assertRaises(ValueError):
                        PLAN.load_event(path)

    def test_main_reports_malformed_event_without_traceback(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "event.json"
            path.write_text("{", encoding="utf-8")
            errors = io.StringIO()
            with (patch.dict(os.environ, {"GITHUB_EVENT_PATH": str(path)}, clear=True),
                  redirect_stderr(errors)):
                result = PLAN.main()

        self.assertEqual(result, 1)
        self.assertIn("CI plan error: cannot read workflow event JSON", errors.getvalue())

    def test_main_reports_invalid_workflow_dispatch_inputs_without_traceback(self):
        cases = (
            ({"inputs": []}, "workflow_dispatch inputs must be an object"),
            ({"inputs": {"probe_iterations": "0"}},
             "probe_iterations must be an integer from 1 to 10"),
        )
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "event.json"
            for event, expected in cases:
                with self.subTest(event=event):
                    path.write_text(json.dumps(event), encoding="utf-8")
                    errors = io.StringIO()
                    with (patch.dict(os.environ, {
                        "GITHUB_EVENT_PATH": str(path),
                        "GITHUB_EVENT_NAME": "workflow_dispatch",
                    }, clear=True), redirect_stderr(errors)):
                        result = PLAN.main()

                    self.assertEqual(result, 1)
                    self.assertIn(f"CI plan error: {expected}", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
