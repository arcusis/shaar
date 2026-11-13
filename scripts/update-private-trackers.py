#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Build the private tracker-domain data from one pinned EasyPrivacy revision."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
from pathlib import Path
import re
import urllib.request


REPOSITORY = "https://github.com/easylist/easylist"
SOURCE_FILES = tuple(f"easyprivacy/easyprivacy_trackingservers{suffix}.txt" for suffix in (
    "", "_general", "_thirdparty", "_international", "_mining", "_admiral", "_notifications"))
DOMAIN_RULE = re.compile(r"\|\|([a-z0-9.-]+)\^(?:\$third-party)?", re.ASCII)
LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", re.ASCII)
OUTPUT = Path(__file__).resolve().parents[1] / "Resources/Privacy/tracker-domains.json"
MAX_SOURCE_BYTES = 4 * 1024 * 1024
# Dedicated analytics/advertising collectors documented by their operator.
# General-purpose Google domains are excluded.
SUPPLEMENTAL_SOURCE = "https://developers.google.com/tag-platform/security/guides/csp"
SUPPLEMENTAL_DOMAINS = (
    "ad.doubleclick.net", "fls.doubleclick.net", "g.doubleclick.net",
    "google-analytics.com", "googleadservices.com", "googletagmanager.com",
    "pagead2.googlesyndication.com",
)


def domains_from(text: str) -> set[str]:
    domains = set()
    for line in text.splitlines():
        match = DOMAIN_RULE.fullmatch(line.strip())
        if not match:
            continue
        domain = match[1]
        if (len(domain) > 253 or "." not in domain
                or not all(LABEL.fullmatch(label) for label in domain.split("."))):
            continue
        try:
            ipaddress.ip_address(domain)
        except ValueError:
            domains.add(domain)
    return domains


def build_rules(revision: str, sources: dict[str, bytes]) -> dict:
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("revision must be a full lowercase Git commit SHA")
    if set(sources) != set(SOURCE_FILES):
        raise ValueError("source inventory must match the pinned EasyPrivacy files")
    domains = set()
    inventory = []
    for name in SOURCE_FILES:
        raw = sources[name]
        if not raw or len(raw) > MAX_SOURCE_BYTES:
            raise ValueError(f"source is empty or exceeds size limit: {name}")
        domains.update(domains_from(raw.decode("utf-8")))
        inventory.append({"path": name, "sha256": hashlib.sha256(raw).hexdigest()})
    if not domains:
        raise ValueError("tracker ruleset has an invalid domain count")
    domains.update(SUPPLEMENTAL_DOMAINS)
    if len(domains) > 100000:
        raise ValueError("tracker ruleset has an invalid domain count")
    ordered = sorted(domains)
    content_hash = hashlib.sha256(("\n".join(ordered) + "\n").encode("utf-8")).hexdigest()
    rules = {
        "schema": 1,
        "revision": f"domain-rules-v1-{content_hash}",
        "license": "CC-BY-SA-3.0",
        "licenseURL": "https://creativecommons.org/licenses/by-sa/3.0/",
        "attribution": "The EasyList authors (https://easylist.to/)",
        "sourceRepository": REPOSITORY,
        "upstreamRevision": revision,
        "coverage": "Third-party requests matching complete domain rules; conditional and path rules omitted.",
        "sources": inventory,
        "supplementalSource": SUPPLEMENTAL_SOURCE,
        "supplementalDomains": list(SUPPLEMENTAL_DOMAINS),
        "domains": ordered,
    }
    if len((json.dumps(rules, indent=2) + "\n").encode("utf-8")) > MAX_SOURCE_BYTES:
        raise ValueError("tracker ruleset exceeds the engine size limit")
    return rules


def fetch_source(revision: str, name: str) -> bytes:
    url = f"https://raw.githubusercontent.com/easylist/easylist/{revision}/{name}"
    with urllib.request.urlopen(url, timeout=30) as response:
        raw = response.read(MAX_SOURCE_BYTES + 1)
    if len(raw) > MAX_SOURCE_BYTES:
        raise ValueError(f"source exceeds size limit: {name}")
    return raw


def write_rules(output: Path, rules: dict) -> None:
    if output.is_symlink():
        raise ValueError(f"tracker rules output must not be a symlink: {output}")
    if output.exists() and not output.is_file():
        raise ValueError(f"tracker rules output is not a regular file: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(rules, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", required=True, help="full EasyPrivacy Git commit SHA")
    parser.add_argument("--output", type=Path, default=OUTPUT)
    arguments = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", arguments.revision):
        parser.error("revision must be a full lowercase Git commit SHA")
    rules = build_rules(arguments.revision, {
        name: fetch_source(arguments.revision, name) for name in SOURCE_FILES})
    write_rules(arguments.output, rules)
    print(f"{len(rules['domains'])} tracker domains; {rules['revision']}")


if __name__ == "__main__":
    main()
