#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Run native sidebar drops offscreen, then restore pinned stacks in a separate process."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--enable-code-coverage", action="store_true")
    options = parser.parse_args()
    coverage = ["--enable-code-coverage"] if options.enable_code_coverage else []
    if not options.skip_build:
        subprocess.run(["swift", "build", "--build-tests", "--jobs", "1", *coverage], cwd=ROOT, check=True)
    parent = ROOT / "build/Verification/sidebar-dnd"
    parent.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix="restart-", dir=parent))
    report = {"passed": False, "physicalInput": False, "visibleWindows": False, "phases": []}
    for phase in ("initial", "restart"):
        environment = dict(os.environ, SHAAR_SIDEBAR_DND_PHASE=phase, SHAAR_SIDEBAR_DND_ROOT=str(evidence))
        selected = "SidebarDnDProbeTests" if phase == "initial" else "SidebarDnDProbeTests/restartProbePhase"
        command = ["swift", "test", "--skip-build", "--jobs", "1", *coverage, "--filter", selected]
        with (evidence / f"{phase}.log").open("w") as log:
            result = subprocess.run(command, cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT)
        receipt = evidence / f"{phase}.json"
        completed = result.returncode == 0 and receipt.is_file()
        if completed:
            completed = json.loads(receipt.read_text()).get("passed") is True
        report["phases"].append({"phase": phase, "passed": completed, "exitCode": result.returncode})
        if not completed:
            (evidence / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            print(f"Sidebar DnD probe failed: {evidence}")
            return 1
    report["passed"] = True
    (evidence / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Sidebar DnD probe passed: {evidence}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
