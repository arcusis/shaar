#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Run Python test files in each direct child test directory under Tests."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
TESTS_ROOT = REPOSITORY_ROOT / "Tests"


def main() -> int:
    sys.path.insert(0, str(REPOSITORY_ROOT))
    test_directories = sorted(path for path in TESTS_ROOT.iterdir() if path.is_dir())
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    discovered_files = 0

    for test_directory in test_directories:
        test_files = sorted(test_directory.glob("test_*.py"))
        if not test_files:
            continue
        discovered_files += len(test_files)
        for test_file in test_files:
            module_spec = importlib.util.spec_from_file_location(test_file.stem, test_file)
            if module_spec is None or module_spec.loader is None:
                print(f"Could not load Python test module: {test_file}", file=sys.stderr)
                return 1
            module = importlib.util.module_from_spec(module_spec)
            sys.modules[module_spec.name] = module
            module_spec.loader.exec_module(module)
            suite.addTests(loader.loadTestsFromModule(module))

    test_count = suite.countTestCases()
    if discovered_files == 0 or test_count == 0:
        print(f"No Python tests discovered under {TESTS_ROOT}", file=sys.stderr)
        return 1

    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
