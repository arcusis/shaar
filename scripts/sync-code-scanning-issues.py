#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Open one GitHub issue per open code-scanning alert and close issues whose alert is gone."""

import argparse
import json
import re
import subprocess

LABEL = "code-scanning"
GH_API_TIMEOUT_SECONDS = 30
TITLE_MARKER = re.compile(r"^\[code-scanning #(\d+)\] ")


def gh(*args: str, payload: dict | None = None) -> dict | list:
    command = ["gh", "api", *args]
    if payload is not None:
        command += ["--input", "-"]
    output = subprocess.check_output(command, text=True, input=json.dumps(payload) if payload else None,
                                     timeout=GH_API_TIMEOUT_SECONDS)
    return json.loads(output) if output.strip() else {}


def paged(path: str) -> list[dict]:
    items, page = [], 1
    while True:
        batch = gh(f"{path}{'&' if '?' in path else '?'}per_page=100&page={page}")
        items.extend(batch)
        if len(batch) < 100:
            return items
        page += 1


def alert_number(issue: dict) -> int | None:
    match = TITLE_MARKER.match(issue.get("title", ""))
    return int(match.group(1)) if match else None


def issue_title(alert: dict) -> str:
    rule = alert["rule"]
    return f"[code-scanning #{alert['number']}] {rule.get('description') or rule['id']}"


def issue_body(alert: dict) -> str:
    rule = alert["rule"]
    location = alert["most_recent_instance"]["location"]
    return "\n".join([
        f"Code scanning found an open alert: {alert['html_url']}",
        "",
        f"- Rule: `{rule['id']}`",
        f"- Severity: {rule.get('security_severity_level') or rule.get('severity') or 'unknown'}",
        f"- Tool: {alert['tool']['name']}",
        f"- Location: `{location['path']}:{location.get('start_line', '?')}`",
        "",
        "Fix the code or dismiss the alert with a reason. This issue closes automatically "
        "after the next scan once the alert is no longer open.",
    ])


def plan(alerts: list[dict], issues: list[dict]) -> tuple[list[dict], list[dict], list[dict]]:
    """Return (alerts needing a new issue, issues to reopen, issues whose alert is no longer open)."""
    open_numbers = {alert["number"] for alert in alerts}
    tracked = {alert_number(issue): issue for issue in issues if alert_number(issue) is not None}
    to_create = [alert for alert in alerts if alert["number"] not in tracked]
    to_reopen = [issue for number, issue in tracked.items()
                 if number in open_numbers and issue.get("state") == "closed"]
    to_close = [issue for number, issue in tracked.items()
                if number not in open_numbers and issue.get("state") == "open"]
    return to_create, to_reopen, to_close


def set_state(repository: str, issue: dict, state: str) -> None:
    gh(f"repos/{repository}/issues/{issue['number']}", "-X", "PATCH", payload={"state": state})


def ensure_labels(repository: str) -> None:
    for name, color in ((LABEL, "b60205"), ("security", "d93f0b")):
        try:
            gh(f"repos/{repository}/labels", "-X", "POST", payload={"name": name, "color": color})
        except subprocess.CalledProcessError:
            pass  # The label already exists.


def sync(repository: str) -> tuple[int, int, int]:
    alerts = paged(f"repos/{repository}/code-scanning/alerts?state=open")
    issues = [issue for issue in paged(f"repos/{repository}/issues?state=all&labels={LABEL}")
              if "pull_request" not in issue]
    to_create, to_reopen, to_close = plan(alerts, issues)
    if to_create:
        ensure_labels(repository)
    for alert in to_create:
        gh(f"repos/{repository}/issues", "-X", "POST",
           payload={"title": issue_title(alert), "body": issue_body(alert), "labels": [LABEL, "security"]})
    for issue in to_reopen:
        set_state(repository, issue, "open")
    for issue in to_close:
        set_state(repository, issue, "closed")
    return len(to_create), len(to_reopen), len(to_close)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    options = parser.parse_args()
    created, reopened, closed = sync(options.repository)
    print(f"Code-scanning issues: {created} opened, {reopened} reopened, {closed} closed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
