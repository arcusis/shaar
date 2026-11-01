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
from collections import Counter
from pathlib import Path

LANGUAGES = ("en", "he")
PLURAL_CATEGORIES = {"en": {"one", "other"}, "he": {"one", "two", "other"}}
PLACEHOLDER = re.compile(r"(?<!%)%(?!%)(?:[0-9]+\$)?[-+#0 ]*(?:[0-9]+)?(?:\.[0-9]+)?(?:hh|h|ll|l|z|t|j)?(?:@|d|i|u|o|x|X|f|F|e|E|g|G|c|C|s|S|p|a|A)")
UNRESOLVED_ARGUMENT = re.compile(r"(?<!%)%arg\b", re.IGNORECASE)


def unit(value, catalog, key, language):
    if not isinstance(value, dict) or value.get("state") != "translated" or not isinstance(value.get("value"), str):
        raise ValueError(f"{catalog.name}: {language} translation for {key!r} missing or not translated")
    if UNRESOLVED_ARGUMENT.search(value["value"]):
        raise ValueError(f"{catalog.name}: unresolved %arg placeholder in {language} translation for {key!r}")
    return value["value"]


def localized_forms(value, catalog, key, language):
    if not isinstance(value, dict):
        raise ValueError(f"{catalog.name}: {language} localization for {key!r} missing or invalid")
    if "stringUnit" in value:
        return {"other": unit(value["stringUnit"], catalog, key, language)}
    variation_data = value.get("variations", {})
    if not isinstance(variation_data, dict):
        raise ValueError(f"{catalog.name}: invalid variation map for {key!r}")
    variations = variation_data.get("plural", {})
    if not isinstance(variations, dict):
        raise ValueError(f"{catalog.name}: invalid plural variation for {key!r}")
    forms = {}
    for category, item in variations.items():
        if not isinstance(item, dict):
            raise ValueError(f"{catalog.name}: invalid {category} plural form for {key!r}")
        forms[category] = unit(item.get("stringUnit"), catalog, key, language)
    expected = PLURAL_CATEGORIES[language]
    if set(forms) != expected:
        raise ValueError(f"{catalog.name}: {language} plural for {key!r} must have {sorted(expected)}")
    return forms


def validate_catalog(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"{path.name}: catalog root must be an object")
    if data.get("sourceLanguage") != "en":
        raise ValueError(f"{path.name}: sourceLanguage must be en")
    strings = data.get("strings")
    if not isinstance(strings, dict) or not strings:
        raise ValueError(f"{path.name}: empty or invalid strings map")
    for key, entry in strings.items():
        if not isinstance(key, str) or not isinstance(entry, dict):
            raise ValueError(f"{path.name}: invalid string entry {key!r}")
        if UNRESOLVED_ARGUMENT.search(key):
            raise ValueError(f"{path.name}: unresolved %arg placeholder in source key {key!r}")
        localizations = entry.get("localizations")
        if not isinstance(localizations, dict):
            raise ValueError(f"{path.name}: localizations map missing or invalid for {key!r}")
        source = localizations.get("en")
        english = localized_forms(source, path, key, "en") if "en" in localizations else {"other": key}
        hebrew = localized_forms(localizations.get("he"), path, key, "he")
        for category in set(english) & set(hebrew):
            english_form = english[category]
            translation = hebrew[category]
            if placeholder_signature(english_form) != placeholder_signature(translation):
                raise ValueError(f"{path.name}: placeholder mismatch in {category} form for {key!r}")


def placeholder_signature(value):
    """Match typed printf arguments while normalizing sequential and positional forms."""
    tokens = PLACEHOLDER.findall(value)
    parsed_tokens = []
    for token in tokens:
        parsed = re.fullmatch(
            r"%([0-9]+\$)?[-+#0 ]*(?:[0-9]+)?(?:\.[0-9]+)?(hh|h|ll|l|z|t|j)?([@diuoxXfFeEgGcCsSpaA])",
            token,
        )
        if parsed is None:
            return None
        index, length, kind = parsed.groups()
        parsed_tokens.append((int(index[:-1]) if index else None, length or "", kind))
    used = {index for index, _, _ in parsed_tokens if index is not None}
    next_index = 1
    normalized = Counter()
    for index, length, kind in parsed_tokens:
        if index is None:
            while next_index in used:
                next_index += 1
            index = next_index
            used.add(index)
            next_index += 1
        normalized[(index, length, kind)] += 1
    return normalized


def compile_native(catalog, output):
    subprocess.run(
        ["xcrun", "xcstringstool", "compile", str(catalog), "--output-directory", str(output),
         "--language", "en", "--language", "he"],
        check=True, capture_output=True, text=True)


def decode_swift_literal(literal):
    value = literal[1:-1]
    value = re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda match: chr(int(match.group(1), 16)), value)
    escapes = {"n": "\n", "r": "\r", "t": "\t", "0": "\0", '"': '"', "\\": "\\"}
    return re.sub(r"\\(.)", lambda match: escapes.get(match.group(1), "\\" + match.group(1)), value)


def swift_string_literals(expression):
    literals = []
    index = 0
    while index < len(expression):
        if expression.startswith('"""', index):
            end = expression.find('"""', index + 3)
            if end < 0:
                break
            literals.append(expression[index + 3:end])
            index = end + 3
        elif expression[index] == '"':
            end = index + 1
            escaped = False
            while end < len(expression):
                if expression[end] == '"' and not escaped:
                    break
                if expression[end] == "\\" and not escaped:
                    escaped = True
                else:
                    escaped = False
                end += 1
            if end >= len(expression):
                break
            literals.append(decode_swift_literal(expression[index:end + 1]))
            index = end + 1
        else:
            index += 1
    return literals


def localization_key_literals(expression):
    """Return key literals from direct or ternary expressions, excluding predicate literals."""
    index = 0
    depths = [0, 0, 0]
    while index < len(expression):
        if expression[index] == '"':
            if expression.startswith('"""', index):
                end = expression.find('"""', index + 3)
                if end < 0:
                    break
                index = end + 3
                continue
            index += 1
            escaped = False
            while index < len(expression):
                if expression[index] == '"' and not escaped:
                    index += 1
                    break
                if expression[index] == "\\" and not escaped:
                    escaped = True
                else:
                    escaped = False
                index += 1
            continue
        if expression[index] == "(":
            depths[0] += 1
        elif expression[index] == ")":
            depths[0] -= 1
        elif expression[index] == "[":
            depths[1] += 1
        elif expression[index] == "]":
            depths[1] -= 1
        elif expression[index] == "{":
            depths[2] += 1
        elif expression[index] == "}":
            depths[2] -= 1
        elif not any(depths) and expression[index] == "?" and not expression.startswith(("??", "?."), index) and (index == 0 or expression[index - 1] != "?"):
            condition_end = index
            nested = 1
            cursor = index + 1
            branch_depths = [0, 0, 0]
            while cursor < len(expression):
                if expression[cursor] == '"':
                    if expression.startswith('"""', cursor):
                        end = expression.find('"""', cursor + 3)
                        if end < 0:
                            break
                        cursor = end + 3
                        continue
                    cursor += 1
                    escaped = False
                    while cursor < len(expression):
                        if expression[cursor] == '"' and not escaped:
                            cursor += 1
                            break
                        if expression[cursor] == "\\" and not escaped:
                            escaped = True
                        else:
                            escaped = False
                        cursor += 1
                    continue
                char = expression[cursor]
                if char == "(": branch_depths[0] += 1
                elif char == ")": branch_depths[0] -= 1
                elif char == "[": branch_depths[1] += 1
                elif char == "]": branch_depths[1] -= 1
                elif char == "{": branch_depths[2] += 1
                elif char == "}": branch_depths[2] -= 1
                elif not any(branch_depths) and char == "?" and not expression.startswith(("??", "?."), cursor) and (cursor == 0 or expression[cursor - 1] != "?"):
                    nested += 1
                elif not any(branch_depths) and char == ":":
                    nested -= 1
                    if nested == 0:
                        condition = expression[:condition_end]
                        true_branch = expression[index + 1:cursor]
                        false_branch = expression[cursor + 1:]
                        return localization_key_literals(true_branch) + localization_key_literals(false_branch)
                cursor += 1
        index += 1
    return swift_string_literals(expression)


def first_argument(source, open_paren):
    depth = 1
    index = open_paren + 1
    start = index
    while index < len(source):
        if source[index] == '"':
            if source.startswith('"""', index):
                end = source.find('"""', index + 3)
                if end < 0:
                    break
                index = end + 3
                continue
            index += 1
            escaped = False
            while index < len(source):
                if source[index] == '"' and not escaped:
                    index += 1
                    break
                if source[index] == "\\" and not escaped:
                    escaped = True
                else:
                    escaped = False
                index += 1
            continue
        if source[index] == "(":
            depth += 1
        elif source[index] == ")":
            depth -= 1
            if depth == 0:
                return source[start:index]
        elif source[index] == "," and depth == 1:
            return source[start:index]
        index += 1
    return source[start:index]


def split_arguments(source, open_paren):
    values = []
    start = open_paren + 1
    depth = 1
    index = start
    while index < len(source):
        if source[index] == '"':
            if source.startswith('"""', index):
                end = source.find('"""', index + 3)
                if end < 0:
                    break
                index = end + 3
                continue
            index += 1
            escaped = False
            while index < len(source):
                if source[index] == '"' and not escaped:
                    index += 1
                    break
                if source[index] == "\\" and not escaped:
                    escaped = True
                else:
                    escaped = False
                index += 1
            continue
        if source[index] == "(":
            depth += 1
        elif source[index] == ")":
            depth -= 1
            if depth == 0:
                values.append(source[start:index])
                return values
        elif source[index] == "," and depth == 1:
            values.append(source[start:index])
            start = index + 1
        index += 1
    return values


def validate_source_references(root, catalogs, include_app=False):
    catalog_keys = {}
    for catalog in catalogs:
        catalog_keys[catalog.stem] = set(json.loads(catalog.read_text(encoding="utf-8"))["strings"])
    wrappers = {"BrowserLocalization": "Core", "ShellL10n": "Shell",
                "SettingsL10n": "Settings", "PanelsL10n": "Panels"}
    call = re.compile(r"\b(BrowserLocalization|ShellL10n|SettingsL10n|PanelsL10n)\.(?:string|text|format|plural)\s*\(")
    source_root = root / "Sources" if include_app else root / "Sources/BrowserCore"
    for path in sorted(source_root.rglob("*.swift")):
        source = path.read_text(encoding="utf-8")
        for match in call.finditer(source):
            wrapper = match.group(1)
            argument = first_argument(source, match.end() - 1)
            for key in localization_key_literals(argument):
                table = wrappers[wrapper]
                if wrapper == "BrowserLocalization":
                    suffix = source[match.end():match.end() + 240]
                    explicit = re.search(r"\btable\s*:\s*\"((?:[^\"\\]|\\.)*)\"", suffix)
                    if explicit:
                        table = decode_swift_literal('"' + explicit.group(1) + '"')
                if key not in catalog_keys.get(table, set()):
                    raise ValueError(f"{table}.xcstrings is missing {wrapper} key {key!r} ({path.relative_to(root)})")
    command_filter = root / "Sources/BrowserCore/CommandLauncher.swift"
    if command_filter.exists() and "rawValue.capitalized" in command_filter.read_text(encoding="utf-8"):
        core_keys = catalog_keys.get("Core", set())
        for key in ("Tabs", "History", "Bookmarks", "Actions"):
            if key not in core_keys:
                raise ValueError(f"Core.xcstrings is missing computed CommandFilter key {key!r}")
    bridge_keys = catalog_keys.get("Bridge", set())
    for path in sorted((root / "Sources/ChromiumBridge").rglob("*.mm")):
        source = path.read_text(encoding="utf-8")
        bridge_refs = re.findall(r"(?:ARCBridgeError|ARCBridgeLocalizedString)\(@\"((?:[^\"\\]|\\.)*)\"\)", source)
        bridge_refs += re.findall(r"localizedStringForKey:@\"((?:[^\"\\]|\\.)*)\"", source)
        for raw in bridge_refs:
            key = decode_swift_literal('"' + raw + '"')
            if key not in bridge_keys:
                raise ValueError(f"Bridge.xcstrings is missing bridge key {key!r}")

    # Native menu titles feed both NSMenu and ShortcutCatalog through computed lookups.
    # Enumerate literals at construction sites so changing either call site cannot evade coverage.
    menu_file = root / "Sources/ArcusisBrowser/NativeBrowserHost.swift"
    if include_app and menu_file.exists():
        source = menu_file.read_text(encoding="utf-8")
        literal = re.compile(r'"(?:[^"\\]|\\.)*"')
        references = []
        for match in re.finditer(r"\b(add|addStandard|section)\s*\(", source):
            args = split_arguments(source, match.end() - 1)
            position = 1 if match.group(1) == "add" else 0
            if len(args) > position:
                value = args[position].strip()
                for token in literal.findall(value):
                    references.append((decode_swift_literal(token), source.count("\n", 0, match.start()) + 1))
        tuple_block = re.search(r"for\s*\(title,\s*action\)\s*in\s*\[(.*?)\]\s*\{", source, re.S)
        if tuple_block:
            for item in re.finditer(r"\(\s*(\"(?:[^\"\\]|\\.)*\")\s*,", tuple_block.group(1)):
                line = source.count("\n", 0, tuple_block.start(1) + item.start(1)) + 1
                references.append((decode_swift_literal(item.group(1)), line))
        for title, line in references:
            if "\\(ProductIdentity.name)" in title:
                replacement = ("About %@" if title.startswith("About ") else
                               "Hide %@" if title.startswith("Hide ") else
                               "Quit %@" if title.startswith("Quit ") else
                               "%@ Support" if title.endswith(" Support") else None)
                if replacement is None:
                    continue
                keys = (replacement,)
            else:
                keys = (title,)
            for table in ("Shell", "Settings"):
                available = catalog_keys.get(table, set())
                for key in keys:
                    if key not in available:
                        raise ValueError(
                            f"{table}.xcstrings is missing native menu key {key!r} "
                            f"(NativeBrowserHost.swift:{line})")


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
        validate_source_references(root, catalogs)
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
