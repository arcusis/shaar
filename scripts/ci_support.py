# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Command evidence shared by CI stages and local fast checks."""

import json
import os
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class Commands:
    def __init__(self, stage: str):
        self.directory = ROOT / "build/ci" / stage
        self.directory.mkdir(parents=True, exist_ok=True)
        self.results = []
        metadata = dict(revision=os.environ.get("GITHUB_SHA", "local"),
                        toolchain=os.environ.get("CI_TOOLCHAIN_ID", "local"))
        (self.directory / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")

    def run(self, name: str, arguments: list[str], *, cwd: Path = ROOT, env=None) -> int:
        print(f"::group::{name}", flush=True)
        started = time.monotonic()
        log = self.directory / f"{name}.log"
        try:
            with log.open("w") as output:
                with subprocess.Popen(
                    arguments, cwd=cwd, env=env, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, text=True,
                ) as process:
                    for line in process.stdout:
                        print(line, end="", flush=True)
                        output.write(line)
                    status = process.wait()
        except OSError as error:
            log.write_text(str(error))
            print(error, flush=True)
            status = 127
        self.results.append(dict(name=name, command=arguments, status=status,
                                 seconds=round(time.monotonic() - started, 3)))
        self.write_reports()
        print("::endgroup::", flush=True)
        return status

    def write_reports(self) -> None:
        (self.directory / "commands.json").write_text(json.dumps(self.results, indent=2) + "\n")
        suite = ET.Element("testsuite", name=self.directory.name, tests=str(len(self.results)),
                           failures=str(sum(item["status"] != 0 for item in self.results)))
        for item in self.results:
            case = ET.SubElement(suite, "testcase", name=item["name"], time=str(item["seconds"]))
            if item["status"]:
                ET.SubElement(case, "failure", message=f"Exit {item['status']}; see {item['name']}.log")
        ET.ElementTree(suite).write(self.directory / "commands.xml", encoding="utf-8", xml_declaration=True)

    def finish(self) -> int:
        self.write_reports()
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with Path(summary).open("a") as output:
                output.write(f"### {self.directory.name}\n\nCommit: `{os.environ.get('GITHUB_SHA', 'local')}`\n\n")
                output.write("| Check | Exit | Seconds |\n| --- | ---: | ---: |\n")
                for item in self.results:
                    output.write(f"| {item['name']} | {item['status']} | {item['seconds']} |\n")
                for report in sorted(self.directory.glob("*.xml")):
                    if report.name == "commands.xml":
                        continue
                    root = ET.parse(report).getroot()
                    suites = [root] if root.tag == "testsuite" else root.findall(".//testsuite")
                    leaves = [suite for suite in suites if not suite.findall("testsuite")]
                    totals = {key: sum(int(suite.get(key, "0")) for suite in leaves)
                              for key in ("tests", "failures", "errors", "skipped")}
                    output.write(f"\n`{report.name}`: {totals['tests']} tests, {totals['failures']} failures, "
                                 f"{totals['errors']} errors, {totals['skipped']} skipped.\n")
        return int(not self.results or any(item["status"] != 0 for item in self.results))
