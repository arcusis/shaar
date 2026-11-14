#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Check a Developer ID profile and merge the iCloud Keychain passkey entitlements.

release.sh calls this only when a provisioning profile is present. A release without
that profile keeps today's camera, microphone and location signature.
"""

from __future__ import annotations

import argparse
import plistlib
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


TEAM_ID = "F9Z784RA6D"
APP_BUNDLE_ID = "com.arcusis.browser"
ENGINE_BUNDLE_ID = "com.arcusis.shaar.engine"
BROWSER_ENTITLEMENT = "com.apple.developer.web-browser.public-key-credential"
APPLICATION_IDENTIFIER = f"{TEAM_ID}.{APP_BUNDLE_ID}"
KEYCHAIN_ACCESS_GROUP = f"{TEAM_ID}.{ENGINE_BUNDLE_ID}.webauthn"


def required_entitlements() -> dict:
    return {
        "com.apple.application-identifier": APPLICATION_IDENTIFIER,
        "com.apple.developer.team-identifier": TEAM_ID,
        BROWSER_ENTITLEMENT: True,
        "keychain-access-groups": [KEYCHAIN_ACCESS_GROUP],
    }


def load_plist(path: Path) -> dict:
    with path.open("rb") as handle:
        value = plistlib.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path} root must be a dictionary")
    return value


def decode_profile(path: Path) -> dict:
    result = subprocess.run(
        ["security", "cms", "-D", "-i", str(path)],
        capture_output=True, check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise ValueError(detail or "security cms could not decode the provisioning profile")
    try:
        value = plistlib.loads(result.stdout)
    except plistlib.InvalidFileException as error:
        raise ValueError(f"decoded profile is not a plist: {error}") from error
    if not isinstance(value, dict):
        raise ValueError("provisioning profile root must be a dictionary")
    return value


def passkey_problems(passkeys: dict) -> list[str]:
    if passkeys != required_entitlements():
        return ["passkey entitlements do not match the release contract"]
    return []


def entitlement_matches(key: str, expected, actual) -> bool:
    if key != "keychain-access-groups":
        if isinstance(expected, bool):
            return type(actual) is bool and actual is expected
        return actual == expected
    if not isinstance(actual, list) or not isinstance(expected, list):
        return False
    try:
        return set(expected) <= set(actual)
    except TypeError:
        return False


def expiration_is_future(value, now: datetime) -> bool:
    if not isinstance(value, datetime):
        return False
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value > now


def profile_problems(profile: dict, now: datetime | None = None) -> list[str]:
    problems = []
    moment = now or datetime.now(timezone.utc)
    if profile.get("TeamIdentifier") != [TEAM_ID]:
        problems.append(f"profile team is not {TEAM_ID}")
    if profile.get("ApplicationIdentifierPrefix") != [TEAM_ID]:
        problems.append(f"profile application identifier prefix is not {TEAM_ID}")
    if profile.get("ProvisionsAllDevices") is not True:
        problems.append("profile is not a Developer ID profile (ProvisionsAllDevices is absent)")
    if "ProvisionedDevices" in profile:
        problems.append("profile is a development profile")
    platform = profile.get("Platform")
    if not isinstance(platform, list) or "OSX" not in platform:
        problems.append("profile is not a macOS profile")
    if not expiration_is_future(profile.get("ExpirationDate"), moment):
        problems.append("profile is expired")
    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict):
        problems.append("profile has no entitlements")
        return problems
    debugger_access = entitlements.get("com.apple.security.get-task-allow", False)
    if debugger_access is True:
        problems.append("profile allows a debugger")
    elif debugger_access is not False:
        problems.append("profile has an invalid debugger entitlement")
    for key, expected in required_entitlements().items():
        if key not in entitlements:
            problems.append(f"profile is missing {key}")
            continue
        if not entitlement_matches(key, expected, entitlements[key]):
            problems.append(f"profile {key} does not match the release contract")
    return problems


def merged_entitlements(base: dict, passkeys: dict) -> dict:
    overlap = [key for key in passkeys if key in base]
    if overlap:
        raise ValueError("base entitlements already contain " + ", ".join(overlap))
    merged = dict(base)
    merged.update(passkeys)
    return merged


def write_plist(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(value, fmt=plistlib.FMT_XML))


def load_profile(profile: Path | None, profile_plist: Path | None) -> dict:
    if (profile is None) == (profile_plist is None):
        raise ValueError("pass exactly one of --profile and --profile-plist")
    if profile_plist is not None:
        return load_plist(profile_plist)
    return decode_profile(profile)


def reject(problems: list[str]) -> None:
    if not problems:
        return
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    raise SystemExit(1)


def command_check(profile: dict) -> None:
    reject(profile_problems(profile))


def command_merge(base_path: Path, passkeys_path: Path, profile: dict, output: Path) -> None:
    base = load_plist(base_path)
    passkeys = load_plist(passkeys_path)
    problems = passkey_problems(passkeys) + profile_problems(profile)
    reject(problems)
    try:
        merged = merged_entitlements(base, passkeys)
    except ValueError as error:
        reject([str(error)])
    write_plist(output, merged)


def add_profile_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--profile", type=Path)
    parser.add_argument("--profile-plist", type=Path)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("check")
    add_profile_arguments(check)
    merge = commands.add_parser("merge")
    merge.add_argument("--base", type=Path, required=True)
    merge.add_argument("--passkeys", type=Path, required=True)
    merge.add_argument("--output", type=Path, required=True)
    add_profile_arguments(merge)
    options = parser.parse_args()
    try:
        profile = load_profile(options.profile, options.profile_plist)
    except ValueError as error:
        reject([str(error)])
        return
    if options.command == "check":
        command_check(profile)
        return
    command_merge(options.base, options.passkeys, profile, options.output)


if __name__ == "__main__":
    main()
