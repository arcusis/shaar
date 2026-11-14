# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Command evidence shared by CI stages and local fast checks."""

import hashlib
import json
import os
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


SWIFT_SOURCE_ROOTS = ("Sources", "Tests/TestSupport")


def swift_source_files(root: Path, scope: str = "full", *, tracked: bool = True,
                       include_build_inputs: bool = False) -> set[str]:
    if scope not in {"full", "shipping"}:
        raise ValueError("Unknown Swift analysis scope")
    roots = (*SWIFT_SOURCE_ROOTS, *(("Package.swift", "Plugins") if include_build_inputs else ()))
    if tracked:
        files = [os.fsdecode(name) for name in subprocess.check_output(
            ["git", "ls-files", "-z", "--", *roots], cwd=root).split(b"\0") if name]
    else:
        files = []
        for name in roots:
            entry = root / name
            candidates = [entry] if entry.is_file() else entry.rglob("*.swift")
            files.extend(path.relative_to(root).as_posix() for path in candidates if path.is_file())
    return {name for name in files if name.endswith(".swift")
            and (scope == "full" or not name.startswith("Sources/ShaarVerification/"))}


def file_sha256(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def junit_totals(report: Path) -> dict[str, int]:
    root = ET.parse(report).getroot()
    suites = [root] if root.tag == "testsuite" else root.findall(".//testsuite")
    leaves = [suite for suite in suites if not suite.findall("testsuite")]
    if not leaves:
        raise ValueError("JUnit report contains no test suites")
    totals = {}
    for key in ("tests", "failures", "errors", "skipped"):
        values = []
        for suite in leaves:
            raw = suite.get(key, "0")
            try:
                value = int(raw)
            except (TypeError, ValueError) as error:
                raise ValueError(f"invalid {key} count {raw!r}") from error
            if value < 0:
                raise ValueError(f"negative {key} count {value}")
            values.append(value)
        totals[key] = sum(values)
    return totals


def output_file(path: Path) -> Path:
    if path.is_symlink():
        raise ValueError(f"CI evidence output must not be a symlink: {path}")
    return path


class Commands:
    def __init__(self, stage: str):
        if not stage or Path(stage).name != stage or stage in {".", ".."}:
            raise ValueError("CI stage must be a single directory name")
        self.directory = ROOT / "build/ci" / stage
        for path in (ROOT / "build", ROOT / "build/ci", self.directory):
            if path.is_symlink():
                raise ValueError(f"CI output path must not be a symlink: {path}")
        self.directory.mkdir(parents=True, exist_ok=True)
        self.results = []
        metadata = dict(revision=os.environ.get("GITHUB_SHA", "local"),
                        toolchain=os.environ.get("CI_TOOLCHAIN_ID", "local"))
        output_file(self.directory / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")

    def run(self, name: str, arguments: list[str], *, cwd: Path = ROOT, env=None) -> int:
        print(f"::group::{name}", flush=True)
        started = time.monotonic()
        log = output_file(self.directory / f"{name}.log")
        try:
            with log.open("w") as output:
                with subprocess.Popen(
                    arguments, cwd=cwd, env=env, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace",
                ) as process:
                    for line in process.stdout:
                        print(line, end="", flush=True)
                        output.write(line)
                    status = process.wait()
        except OSError as error:
            output_file(log).write_text(str(error))
            print(error, flush=True)
            status = 127
        self.results.append(dict(name=name, command=arguments, status=status,
                                 seconds=round(time.monotonic() - started, 3)))
        self.write_reports()
        print("::endgroup::", flush=True)
        return status

    def write_reports(self) -> None:
        commands_json = output_file(self.directory / "commands.json")
        commands_xml = output_file(self.directory / "commands.xml")
        commands_json.write_text(json.dumps(self.results, indent=2) + "\n")
        suite = ET.Element("testsuite", name=self.directory.name, tests=str(len(self.results)),
                           failures=str(sum(item["status"] != 0 for item in self.results)))
        for item in self.results:
            case = ET.SubElement(suite, "testcase", name=item["name"], time=str(item["seconds"]))
            if item["status"]:
                ET.SubElement(case, "failure", message=f"Exit {item['status']}; see {item['name']}.log")
        ET.ElementTree(suite).write(commands_xml, encoding="utf-8", xml_declaration=True)

    def finish(self) -> int:
        invalid_reports = []
        report_totals = {}
        for report in sorted(self.directory.glob("*.xml")):
            if report.name == "commands.xml":
                continue
            try:
                report_totals[report.name] = junit_totals(report)
            except (ET.ParseError, OSError, ValueError) as error:
                name = f"invalid-report-{report.name}"
                action = "parse" if isinstance(error, (ET.ParseError, OSError)) else "validate"
                message = f"Could not {action} {report.name}: {error}"
                output_file(self.directory / f"{name}.log").write_text(message + "\n")
                self.results.append(dict(name=name, command=["validate XML report", str(report)],
                                         status=1, seconds=0.0))
                invalid_reports.append(message)
        self.write_reports()
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with output_file(Path(summary)).open("a") as output:
                output.write(f"### {self.directory.name}\n\nCommit: `{os.environ.get('GITHUB_SHA', 'local')}`\n\n")
                output.write("| Check | Exit | Seconds |\n| --- | ---: | ---: |\n")
                for item in self.results:
                    output.write(f"| {item['name']} | {item['status']} | {item['seconds']} |\n")
                for message in invalid_reports:
                    output.write(f"\n{message}\n")
                for report in sorted(self.directory.glob("*.xml")):
                    totals = report_totals.get(report.name)
                    if totals is None:
                        continue
                    output.write(f"\n`{report.name}`: {totals['tests']} tests, {totals['failures']} failures, "
                                 f"{totals['errors']} errors, {totals['skipped']} skipped.\n")
        return int(not self.results or any(item["status"] != 0 for item in self.results))
