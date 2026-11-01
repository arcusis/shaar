#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Validate String Catalog coverage and invoke Apple's native catalog compiler."""
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

LANGUAGES = ("en", "he")
PLURAL_CATEGORIES = {"en": {"one", "other"}, "he": {"one", "two", "other"}}
PLACEHOLDER = re.compile(r"%(?:[0-9]+\$)?[-+#0 ]*(?:[0-9]+)?(?:\.[0-9]+)?(?:hh|h|ll|l|z|t|j)?(?:@|d|i|u|o|x|X|f|F|e|E|g|G|c|C|s|S|p|a|A)")


def unit(value, catalog, key, language):
    if not isinstance(value, dict) or value.get("state") != "translated" or not isinstance(value.get("value"), str):
        raise ValueError(f"{catalog.name}: {language} translation for {key!r} missing or not translated")
    return value["value"]


def localized_forms(value, catalog, key, language):
    if "stringUnit" in value:
        return {"other": unit(value["stringUnit"], catalog, key, language)}
    variations = value.get("variations", {}).get("plural", {})
    if not isinstance(variations, dict):
        raise ValueError(f"{catalog.name}: invalid plural variation for {key!r}")
    forms = {category: unit(item.get("stringUnit"), catalog, key, language)
             for category, item in variations.items()}
    expected = PLURAL_CATEGORIES[language]
    if set(forms) != expected:
        raise ValueError(f"{catalog.name}: {language} plural for {key!r} must have {sorted(expected)}")
    return forms


def validate_catalog(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("sourceLanguage") != "en":
        raise ValueError(f"{path.name}: sourceLanguage must be en")
    strings = data.get("strings")
    if not isinstance(strings, dict) or not strings:
        raise ValueError(f"{path.name}: empty or invalid strings map")
    for key, entry in strings.items():
        localizations = entry.get("localizations", {})
        if not isinstance(key, str) or not isinstance(localizations, dict):
            raise ValueError(f"{path.name}: invalid string entry {key!r}")
        source = localizations.get("en")
        english = localized_forms(source, path, key, "en") if source else {"other": key}
        hebrew = localized_forms(localizations.get("he"), path, key, "he")
        for category in set(english) & set(hebrew):
            if sorted(PLACEHOLDER.findall(english[category])) != sorted(PLACEHOLDER.findall(hebrew[category])):
                raise ValueError(f"{path.name}: placeholder mismatch in {category} form for {key!r}")


def compile_native(catalog, output):
    subprocess.run(
        ["xcrun", "xcstringstool", "compile", str(catalog), "--output-directory", str(output),
         "--language", "en", "--language", "he"],
        check=True, capture_output=True, text=True)


def validate_source_references(root, core_catalog, bridge_catalog):
    core_keys = set(json.loads(core_catalog.read_text(encoding="utf-8"))["strings"])
    bridge_keys = set(json.loads(bridge_catalog.read_text(encoding="utf-8"))["strings"])
    swift_source = "\n".join(path.read_text(encoding="utf-8") for path in (root / "Sources/BrowserCore").glob("*.swift"))
    for key in re.findall(r"BrowserLocalization\.(?:string|format|plural)\(\s*\"((?:[^\"\\]|\\.)*)\"", swift_source):
        if key not in core_keys:
            raise ValueError(f"Core.xcstrings is missing BrowserLocalization key {key!r}")
    bridge_source = "\n".join(path.read_text(encoding="utf-8") for path in (root / "Sources/ChromiumBridge").glob("*.mm"))
    bridge_references = re.findall(r"(?:ARCBridgeError|ARCBridgeLocalizedString)\(@\"([^\"]+)\"\)", bridge_source)
    bridge_references += re.findall(r"localizedStringForKey:@\"([^\"]+)\"", bridge_source)
    for key in bridge_references:
        if key not in bridge_keys:
            raise ValueError(f"Bridge.xcstrings is missing bridge key {key!r}")


def main():
    if len(sys.argv) != 3:
        raise SystemExit("Usage: compile-localizations.py PACKAGE_ROOT OUTPUT_DIR")
    root, output = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    core = root / "Sources/BrowserCore/Resources"
    catalogs = sorted(core.glob("*.xcstrings")) + sorted((root / "Resources/Localizations").glob("*.xcstrings"))
    if not catalogs:
        raise SystemExit("No String Catalogs found")
    try:
        for catalog in catalogs:
            validate_catalog(catalog)
        validate_source_references(root, core / "Core.xcstrings", core / "Bridge.xcstrings")
        output.mkdir(parents=True, exist_ok=True)
        marker = output / "LocalizationCatalogValidation.swift"
        if marker.is_symlink():
            raise ValueError(f"refusing to replace symlinked plugin output {marker}")
        marker.unlink(missing_ok=True)
        for language in ("en.lproj", "he.lproj"):
            target = output / language
            if target.is_symlink():
                raise ValueError(f"refusing to replace symlinked plugin output {target}")
            if target.exists():
                shutil.rmtree(target)
        with tempfile.TemporaryDirectory(prefix="shaar-xcstrings-") as temp:
            temporary = Path(temp)
            for catalog in catalogs:
                destination = output if catalog.parent == core else temporary
                compile_native(catalog, destination)
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "stderr", "")
        raise SystemExit(f"Localization catalog validation failed: {error} {detail or ''}".strip()) from error


if __name__ == "__main__":
    main()
