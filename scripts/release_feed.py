#!/usr/bin/env python3
"""Shaar release names, Sparkle appcast rendering, and appcast/update validation.

release.sh uses this to name assets and write the appcast; the Release workflow uses the
same checks against the published feed and update ZIP, so both sides share one contract.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import email.utils
import plistlib
import re
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from dataclasses import dataclass
from pathlib import Path


CONFIG_PATH = Path(__file__).resolve().with_name("release-config.sh")
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
APP_NAME = "Shaar.app"
# bash sources the config, so every value is limited to characters with no shell meaning.
CONFIG_LINE = re.compile(r"(SHAAR_[A-Z_]+)=([A-Za-z0-9._:/+=-]+)")
BUNDLE_IDENTIFIER = re.compile(r"[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+")
BUNDLE_VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
SYSTEM_VERSION = re.compile(r"[0-9]+\.[0-9]+(\.[0-9]+)?")
BUILD_VERSION = re.compile(r"[1-9][0-9]*")
REPOSITORY = re.compile(r"[A-Za-z0-9-]+/[A-Za-z0-9._-]+")
REQUIRED_KEYS = (
    "SHAAR_BUNDLE_IDENTIFIER",
    "SHAAR_BUNDLE_VERSION",
    "SHAAR_BUILD_VERSION",
    "SHAAR_MINIMUM_SYSTEM_VERSION",
    "SHAAR_RELEASE_REPOSITORY",
    "SHAAR_FEED_URL",
    "SHAAR_SPARKLE_PUBLIC_ED_KEY",
)


class ReleaseError(Exception):
    """A release input or published artifact breaks the release contract."""


@dataclass(frozen=True)
class ReleaseConfig:
    bundle_identifier: str
    bundle_version: str
    build_version: int
    minimum_system_version: str
    repository: str
    feed_url: str
    public_ed_key: str

    @property
    def tag(self) -> str:
        return f"v{self.bundle_version}"

    @property
    def dmg_name(self) -> str:
        return f"Shaar_{self.bundle_version}_aarch64.dmg"

    @property
    def zip_name(self) -> str:
        return f"Shaar-{self.bundle_version}-macos.zip"

    @property
    def appcast_name(self) -> str:
        return "appcast.xml"

    @property
    def zip_url(self) -> str:
        return f"https://github.com/{self.repository}/releases/download/{self.tag}/{self.zip_name}"

    @property
    def public_key_is_ready(self) -> bool:
        return is_ed25519_public_key(self.public_ed_key)


@dataclass(frozen=True)
class AppcastItem:
    title: str
    bundle_version: str
    build_version: int
    minimum_system_version: str
    url: str
    length: int
    signature: str | None


def is_ed25519_public_key(value: str) -> bool:
    try:
        return len(base64.b64decode(value, validate=True)) == 32
    except (binascii.Error, ValueError):
        return False


def parse_config(text: str) -> ReleaseConfig:
    values: dict[str, str] = {}
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = CONFIG_LINE.fullmatch(line)
        if match is None:
            raise ReleaseError(
                f"release config line {number} must be SHAAR_KEY=value using only A-Z a-z 0-9 . _ : / + = -: {raw!r}"
            )
        values[match.group(1)] = match.group(2)
    missing = [key for key in REQUIRED_KEYS if key not in values]
    if missing:
        raise ReleaseError(f"release config is missing {', '.join(missing)}")
    config = ReleaseConfig(
        bundle_identifier=values["SHAAR_BUNDLE_IDENTIFIER"],
        bundle_version=values["SHAAR_BUNDLE_VERSION"],
        build_version=_build_number(values["SHAAR_BUILD_VERSION"], "release config build"),
        minimum_system_version=values["SHAAR_MINIMUM_SYSTEM_VERSION"],
        repository=values["SHAAR_RELEASE_REPOSITORY"],
        feed_url=values["SHAAR_FEED_URL"],
        public_ed_key=values["SHAAR_SPARKLE_PUBLIC_ED_KEY"],
    )
    if not BUNDLE_IDENTIFIER.fullmatch(config.bundle_identifier):
        raise ReleaseError(f"bundle identifier {config.bundle_identifier!r} must be reverse-DNS")
    if not SYSTEM_VERSION.fullmatch(config.minimum_system_version):
        raise ReleaseError(f"minimum system version {config.minimum_system_version!r} must be Major.Minor")
    if not BUNDLE_VERSION.fullmatch(config.bundle_version):
        raise ReleaseError(f"bundle version {config.bundle_version!r} must be Major.Minor.Patch")
    if not REPOSITORY.fullmatch(config.repository):
        raise ReleaseError(f"release repository {config.repository!r} must be owner/name")
    if not config.feed_url.startswith("https://"):
        raise ReleaseError(f"feed URL {config.feed_url!r} must use HTTPS")
    return config


def load_config(path: Path = CONFIG_PATH) -> ReleaseConfig:
    return parse_config(path.read_text(encoding="utf-8"))


def _build_number(value: str, label: str) -> int:
    if not BUILD_VERSION.fullmatch(value):
        raise ReleaseError(f"{label} {value!r} must be a positive integer")
    return int(value)


def render_appcast(
    config: ReleaseConfig, *, length: int, signature: str | None, notes_html: str, pub_date: str
) -> str:
    if "]]>" in notes_html:
        raise ReleaseError("release notes must not contain ']]>'")
    if not notes_html.strip():
        raise ReleaseError("release notes are empty")
    signature_attribute = f' sparkle:edSignature="{signature}"' if signature else ""
    return f"""<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="{SPARKLE_NAMESPACE}" version="2.0">
    <channel>
        <title>Shaar</title>
        <item>
            <title>{config.bundle_version}</title>
            <description><![CDATA[
                <h3>What's New in {config.tag}</h3>
                <ul>
{notes_html.rstrip()}
                </ul>
            ]]></description>
            <pubDate>{pub_date}</pubDate>
            <sparkle:version>{config.build_version}</sparkle:version>
            <sparkle:shortVersionString>{config.bundle_version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{config.minimum_system_version}</sparkle:minimumSystemVersion>
            <enclosure url="{config.zip_url}" length="{length}" type="application/octet-stream"{signature_attribute}/>
        </item>
    </channel>
</rss>
"""


def _sparkle(name: str) -> str:
    return f"{{{SPARKLE_NAMESPACE}}}{name}"


def parse_appcast(text: str) -> AppcastItem:
    try:
        root = ET.fromstring(text)
    except ET.ParseError as error:
        raise ReleaseError(f"appcast is not valid XML: {error}") from None
    items = root.findall("./channel/item")
    if len(items) != 1:
        raise ReleaseError(f"expected exactly one appcast item, found {len(items)}")
    item = items[0]
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ReleaseError("appcast item has no enclosure")

    def field(tag: str) -> str:
        return (item.findtext(tag) or "").strip()

    return AppcastItem(
        title=field("title"),
        bundle_version=field(_sparkle("shortVersionString")),
        build_version=_build_number(field(_sparkle("version")), "appcast build"),
        minimum_system_version=field(_sparkle("minimumSystemVersion")),
        url=enclosure.get("url", ""),
        length=_build_number(enclosure.get("length", ""), "appcast enclosure length"),
        signature=enclosure.get(_sparkle("edSignature")),
    )


def validate_appcast(text: str, config: ReleaseConfig, *, require_signature: bool = True) -> AppcastItem:
    item = parse_appcast(text)
    expected = {
        "title": (item.title, config.bundle_version),
        "shortVersionString": (item.bundle_version, config.bundle_version),
        "version": (item.build_version, config.build_version),
        "minimumSystemVersion": (item.minimum_system_version, config.minimum_system_version),
        "enclosure URL": (item.url, config.zip_url),
    }
    for name, (actual, wanted) in expected.items():
        if actual != wanted:
            raise ReleaseError(f"appcast {name} {actual!r} does not match {wanted!r}")
    if require_signature and not item.signature:
        raise ReleaseError("appcast enclosure has no Sparkle EdDSA signature")
    return item


def validate_update_zip(path: Path, config: ReleaseConfig, *, expected_length: int) -> None:
    actual_length = path.stat().st_size
    if actual_length != expected_length:
        raise ReleaseError(f"update ZIP is {actual_length} bytes; appcast says {expected_length}")
    with zipfile.ZipFile(path) as archive:
        entries = [name for name in archive.namelist() if name.endswith(f"{APP_NAME}/Contents/Info.plist")]
        if entries != [f"{APP_NAME}/Contents/Info.plist"]:
            raise ReleaseError(f"expected one top-level {APP_NAME} Info.plist, found {entries}")
        info = plistlib.loads(archive.read(entries[0]))
    expected = {
        "CFBundleIdentifier": config.bundle_identifier,
        "CFBundleShortVersionString": config.bundle_version,
        "CFBundleVersion": str(config.build_version),
        "SUFeedURL": config.feed_url,
        "SUPublicEDKey": config.public_ed_key,
    }
    for key, value in expected.items():
        actual = str(info.get(key, ""))
        if actual != value:
            raise ReleaseError(f"update ZIP {key} {actual!r} does not match {value!r}")


def verify_update_signature(path: Path, signature: str, public_key: str) -> None:
    """Checks the appcast's Ed25519 signature over the ZIP bytes, as Sparkle does before installing."""
    try:
        from cryptography.exceptions import InvalidSignature
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    except ModuleNotFoundError:
        raise ReleaseError(
            "signature checks need the pinned packages in scripts/release-requirements.txt"
        ) from None

    if not is_ed25519_public_key(public_key):
        raise ReleaseError("SUPublicEDKey is not a real Ed25519 public key")
    try:
        signature_bytes = base64.b64decode(signature, validate=True)
        Ed25519PublicKey.from_public_bytes(base64.b64decode(public_key)).verify(signature_bytes, path.read_bytes())
    except (binascii.Error, ValueError, InvalidSignature):
        raise ReleaseError("update ZIP does not match the appcast's EdDSA signature for SUPublicEDKey") from None


def fetch_published_appcast(url: str) -> str | None:
    """Returns the live feed, or None only when it does not exist yet (HTTP 404)."""
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            return response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise ReleaseError(f"published feed {url} returned HTTP {error.code}") from None
    except urllib.error.URLError as error:
        raise ReleaseError(f"cannot read published feed {url}: {error.reason}") from None


def ensure_newer_than_published(config: ReleaseConfig, published_appcast: str) -> int:
    published = parse_appcast(published_appcast).build_version
    if config.build_version <= published:
        raise ReleaseError(
            f"build {config.build_version} is not newer than published Sparkle build {published}; "
            "increment SHAAR_BUILD_VERSION in scripts/release-config.sh"
        )
    return published


def _describe(config: ReleaseConfig, _: argparse.Namespace) -> None:
    print(config.tag, config.dmg_name, config.zip_name, config.appcast_name)


def _check_key(config: ReleaseConfig, _: argparse.Namespace) -> None:
    if not config.public_key_is_ready:
        raise ReleaseError(
            "SHAAR_SPARKLE_PUBLIC_ED_KEY is not a real Ed25519 public key; "
            "set it to the output of `generate_keys --account shaar`"
        )


def _check_newer(config: ReleaseConfig, arguments: argparse.Namespace) -> None:
    url = arguments.feed_url or config.feed_url
    published_appcast = fetch_published_appcast(url)
    if published_appcast is None:
        print(f"No feed at {url} yet (HTTP 404); this is the first release.")
        return
    published = ensure_newer_than_published(config, published_appcast)
    print(f"Build {config.build_version} is newer than published build {published}.")


def _write(config: ReleaseConfig, arguments: argparse.Namespace) -> None:
    appcast = render_appcast(
        config,
        length=arguments.zip.stat().st_size,
        signature=arguments.signature,
        notes_html=arguments.notes.read_text(encoding="utf-8"),
        pub_date=email.utils.formatdate(usegmt=True),
    )
    arguments.output.write_text(appcast, encoding="utf-8")


def _validate(config: ReleaseConfig, arguments: argparse.Namespace) -> None:
    item = validate_appcast(
        arguments.appcast.read_text(encoding="utf-8"), config, require_signature=not arguments.allow_unsigned
    )
    validate_update_zip(arguments.zip, config, expected_length=item.length)
    if item.signature:
        verify_update_signature(arguments.zip, item.signature, config.public_ed_key)
    print(f"Validated {config.tag}: bundle {config.bundle_version}, build {config.build_version}.")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=CONFIG_PATH)
    commands = parser.add_subparsers(dest="command", required=True)
    describe = commands.add_parser("describe", help="print tag and the DMG, ZIP and appcast asset names")
    describe.set_defaults(run=_describe)
    commands.add_parser("check-key", help="require a real Sparkle public key").set_defaults(run=_check_key)
    newer = commands.add_parser("check-newer", help="require a build above the live feed (404 = first release)")
    newer.add_argument("--feed-url", help="feed to check instead of SHAAR_FEED_URL")
    newer.set_defaults(run=_check_newer)
    write = commands.add_parser("write", help="write the single-item appcast")
    write.add_argument("--zip", type=Path, required=True)
    write.add_argument("--notes", type=Path, required=True)
    write.add_argument("--signature")
    write.add_argument("--output", type=Path, required=True)
    write.set_defaults(run=_write)
    validate = commands.add_parser("validate", help="check appcast and update ZIP against the config")
    validate.add_argument("--appcast", type=Path, required=True)
    validate.add_argument("--zip", type=Path, required=True)
    validate.add_argument("--allow-unsigned", action="store_true")
    validate.set_defaults(run=_validate)
    arguments = parser.parse_args(argv)
    try:
        arguments.run(load_config(arguments.config), arguments)
    except (ReleaseError, OSError, zipfile.BadZipFile) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
