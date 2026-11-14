# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from contextlib import redirect_stderr
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("test_python_runner", ROOT / "scripts/test-python.py")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class PythonTestDiscoveryTests(unittest.TestCase):
    def run_runner(self, repository):
        errors = io.StringIO()
        original_sys_path = RUNNER.sys.path[:]
        try:
            with (patch.object(RUNNER, "REPOSITORY_ROOT", repository),
                  patch.object(RUNNER, "TESTS_ROOT", repository / "Tests"),
                  patch.object(RUNNER.sys, "argv", ["test-python.py"]),
                  redirect_stderr(errors)):
                result = RUNNER.main()
        finally:
            RUNNER.sys.path[:] = original_sys_path
        return result, errors.getvalue()

    def test_symlinked_test_directory_is_rejected_before_import(self):
        with tempfile.TemporaryDirectory() as temporary, tempfile.TemporaryDirectory() as outside:
            repository = Path(temporary)
            tests = repository / "Tests"
            tests.mkdir()
            external = Path(outside)
            marker = external / "imported"
            module = external / "test_external.py"
            module.write_text(f"from pathlib import Path\nPath({str(marker)!r}).write_text('ran')\n")
            (tests / "External").symlink_to(external, target_is_directory=True)

            result, error = self.run_runner(repository)

            self.assertEqual(result, 1)
            self.assertIn("Python test directory must not be a symlink", error)
            self.assertFalse(marker.exists())

    def test_symlinked_test_file_is_rejected_before_import(self):
        with tempfile.TemporaryDirectory() as temporary, tempfile.TemporaryDirectory() as outside:
            repository = Path(temporary)
            suite = repository / "Tests" / "Suite"
            suite.mkdir(parents=True)
            external = Path(outside)
            marker = external / "imported"
            module = external / "test_external.py"
            module.write_text(f"from pathlib import Path\nPath({str(marker)!r}).write_text('ran')\n")
            (suite / "test_external.py").symlink_to(module)

            result, error = self.run_runner(repository)

            self.assertEqual(result, 1)
            self.assertIn("Python test file must not be a symlink", error)
            self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
