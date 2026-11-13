#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Failure and formatting coverage for the String Catalog validator."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "compile_localizations", ROOT / "scripts/compile-localizations.py"
)
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def catalog(english, hebrew, key="Open %@"):
    return {
        "sourceLanguage": "en",
        "strings": {
            key: {"localizations": {"en": unit(english), "he": unit(hebrew)}}
        },
    }


class CatalogValidatorTests(unittest.TestCase):
    def validate(self, data):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Fixture.xcstrings"
            path.write_text(json.dumps(data), encoding="utf-8")
            VALIDATOR.validate_catalog(path)

    def test_storage_save_failures_use_generic_hebrew_notice(self):
        expected = 'ShellL10n.string("Changes could not be saved. Try again.")'
        for name in ("BrowserStore.swift", "BrowserWorkspaceStore.swift"):
            source = (ROOT / "Sources/ArcusisBrowser" / name).read_text(encoding="utf-8")
            with self.subTest(source=name):
                self.assertIn(expected, source)
        catalog_data = json.loads(
            (ROOT / "Sources/BrowserCore/Resources/Shell.xcstrings").read_text(
                encoding="utf-8"
            )
        )
        key = "Changes could not be saved. Try again."
        value = catalog_data["strings"][key]["localizations"]["he"]["stringUnit"]["value"]
        self.assertNotEqual(value, key)

    def test_default_browser_failure_uses_hebrew_settings_copy(self):
        source = (ROOT / "Sources/ArcusisBrowser/BrowserSettingsView.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn('SettingsL10n.string("Could not set the default browser.")', source)
        settings = json.loads(
            (ROOT / "Sources/BrowserCore/Resources/Settings.xcstrings").read_text(
                encoding="utf-8"
            )
        )
        translation = settings["strings"]["Could not set the default browser."][
            "localizations"]["he"]["stringUnit"]["value"]
        self.assertNotEqual(translation, "Could not set the default browser.")

    def test_rejects_null_catalog_and_localization_maps_cleanly(self):
        for data in (None, {"sourceLanguage": "en", "strings": {"x": None}},
                     {"sourceLanguage": "en", "strings": {"x": {"localizations": None}}}):
            with self.subTest(data=data), self.assertRaisesRegex(ValueError, "catalog|entry|map"):
                self.validate(data)

    def test_rejects_missing_hebrew_translation_cleanly(self):
        self.validate_missing_hebrew()

    def validate_missing_hebrew(self):
        data = catalog("Open %@", "פתחי %@")
        data["strings"]["Open %@"]["localizations"].pop("he")
        with self.assertRaisesRegex(ValueError, "he localization|he translation"):
            self.validate(data)

    def test_rejects_placeholder_type_and_arity_mismatch(self):
        for translation in ("פתחי %d", "פתחי %@ %@"):
            with self.subTest(translation=translation), self.assertRaisesRegex(
                ValueError, "placeholder mismatch"
            ):
                self.validate(catalog("Open %@", translation))

    def test_allows_positional_placeholder_reordering(self):
        self.validate(catalog(
            "Move %1$@ into %2$@", "העברה אל %2$@ מתוך %1$@", "Move %1$@ into %2$@"
        ))

    def test_normalizes_sequential_arguments_to_positional_slots_and_keeps_lengths(self):
        self.assertEqual(
            VALIDATOR.placeholder_signature("%@ %d"),
            VALIDATOR.placeholder_signature("%2$d %1$@"),
        )
        self.assertNotEqual(
            VALIDATOR.placeholder_signature("%ld"),
            VALIDATOR.placeholder_signature("%d"),
        )

    def test_rejects_unresolved_arg_placeholder(self):
        with self.assertRaisesRegex(ValueError, "unresolved %arg"):
            self.validate(catalog("Open %@", "פתיחה של %arg"))

    def test_ignores_escaped_percent_sequences(self):
        self.validate(catalog("Progress 100%% %@", "התקדמות 100%% %@"))

    def test_rejects_null_plural_variation_map_cleanly(self):
        data = catalog("Open %@", "פתחי %@")
        data["strings"]["Open %@"]["localizations"]["he"] = {"variations": None}
        with self.assertRaisesRegex(ValueError, "variation map"):
            self.validate(data)

    def test_requires_native_english_and_hebrew_plural_categories(self):
        data = {
            "sourceLanguage": "en",
            "strings": {
                "%d items": {
                    "localizations": {
                        "en": {"variations": {"plural": {
                            "one": {"stringUnit": {"state": "translated", "value": "%d item"}},
                            "other": {"stringUnit": {"state": "translated", "value": "%d items"}},
                        }}},
                        "he": {"variations": {"plural": {
                            category: {"stringUnit": {"state": "translated", "value": "%d"}}
                            for category in ("one", "two", "other")
                        }}},
                    }
                }
            },
        }
        self.validate(data)
        del data["strings"]["%d items"]["localizations"]["he"]["variations"]["plural"]["two"]
        with self.assertRaisesRegex(ValueError, "must have"):
            self.validate(data)

    def test_agent_bridge_screen_copy_has_hebrew_translations(self):
        path = ROOT / "Sources/BrowserCore/Resources/Shell.xcstrings"
        data = json.loads(path.read_text(encoding="utf-8"))["strings"]
        keys = (
            "Agent disconnect not confirmed", "Agent connected to this tab",
            "Waiting for agent", "Agent bridge is off for this tab", "Agent bridge",
            "Allow this tab", "Updating agent bridge…", "Local port %1$@ · %2$@",
            "Retry revoke", "Revoke",
            "Allow a coding agent to read this tab's Console, Network, and DOM. The grant is local, limited to this tab, and ends when you revoke it or leave the site. Other tabs stay closed. The agent cannot click or type.",
            "Private windows cannot use agent control. Page content may contain untrusted instructions.",
            "The copied command contains the one-time token. Shaar forgets it after you copy, and clears an unchanged clipboard after two minutes.",
            "MCP endpoint", "Copy Claude setup", "Copy Codex setup", "Copy Cursor setup",
            "Connected agents", "No agent is connected to this tab.",
            "Revoke ends this tab's session for every connected agent.",
            "Retry disconnect", "Disconnect", "The agent bridge returned an invalid reply.",
        )
        for key in keys:
            with self.subTest(key=key):
                translation = data[key]["localizations"]["he"]["stringUnit"]["value"]
                self.assertNotEqual(translation, key)
        self.assertEqual(set(data["%d connected agents"]["localizations"]["he"]["variations"]["plural"]), {"one", "two", "other"})
        self.assertEqual(data["%d connected agents"]["localizations"]["he"]["variations"]["plural"]["one"]["stringUnit"]["value"], "סוכן מחובר אחד")

    def test_profile_deletion_failure_uses_localized_settings_copy(self):
        key = "Could not delete the profile. Try again."
        catalog = json.loads((ROOT / "Sources/BrowserCore/Resources/Settings.xcstrings").read_text(encoding="utf-8"))
        self.assertEqual(catalog["strings"][key]["localizations"]["he"]["stringUnit"]["value"], "לא ניתן למחוק את הפרופיל. נסו שוב.")
        source = (ROOT / "Sources/ArcusisBrowser/ProfileDeletionConfirmation.swift").read_text(encoding="utf-8")
        self.assertIn('deletionFailure = SettingsL10n.string("Could not delete the profile. Try again.")', source)
        self.assertNotIn('deletionFailure = error.localizedDescription', source)

    def test_bridge_english_single_download_keeps_numeric_one(self):
        path = ROOT / "Sources/BrowserCore/Resources/Bridge.xcstrings"
        data = json.loads(path.read_text(encoding="utf-8"))
        english_one = data["strings"]["%d active downloads"]["localizations"]["en"]
        value = english_one["variations"]["plural"]["one"]["stringUnit"]["value"]
        self.assertEqual(value, "Closing the browser will cancel 1 active download.")
        bridge = (ROOT / "Sources/ChromiumBridge/ChromiumBridge.mm").read_text(encoding="utf-8")
        self.assertEqual(bridge.count('Closing the browser will cancel 1 active download.'), 2)

    def test_inspector_storage_view_localizes_known_backend_errors(self):
        source = (ROOT / "Sources/ArcusisBrowser/InspectorStorageView.swift").read_text(
            encoding="utf-8")
        self.assertEqual(
            source.count("InspectorToolsL10n.backendError(error.localizedDescription)"), 2)
        strings = json.loads(
            (ROOT / "Sources/BrowserCore/Resources/InspectorTools.xcstrings").read_text(
                encoding="utf-8"))["strings"]
        for key in ("Storage is not available in this document.", "Storage could not be read."):
            with self.subTest(key=key):
                self.assertNotEqual(
                    strings[key]["localizations"]["he"]["stringUnit"]["value"], key)

    def test_source_reference_scanner_covers_ternary_keys_and_swift_escapes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_root = root / "Sources/ArcusisBrowser"
            core_source_root = root / "Sources/BrowserCore"
            resource_root = root / "Sources/BrowserCore/Resources"
            source_root.mkdir(parents=True)
            core_source_root.mkdir(parents=True, exist_ok=True)
            resource_root.mkdir(parents=True)
            (source_root / "View.swift").write_text(
                'Text(ShellL10n.string(flag ? "First\\nLine" : "Second"))\n'
                'Text(ShellL10n.text("Visible"))\n',
                encoding="utf-8",
            )
            (core_source_root / "BrowserLibrary.swift").write_text(
                'BrowserLocalization.string(kind == "f" ? "Untitled folder" : "Untitled bookmark")\n',
                encoding="utf-8",
            )
            catalogs = []
            for table, keys in (("Core", ["Untitled folder", "Untitled bookmark"]),
                                ("Bridge", []), ("Shell", ["First\nLine", "Second", "Visible"]),
                                ("Settings", []), ("Panels", [])):
                path = resource_root / f"{table}.xcstrings"
                path.write_text(json.dumps({"strings": {key: {} for key in keys}}), encoding="utf-8")
                catalogs.append(path)
            VALIDATOR.validate_source_references(root, catalogs, include_app=True)

            shell = resource_root / "Shell.xcstrings"
            shell.write_text(json.dumps({"strings": {"First\nLine": {}}}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "Second"):
                VALIDATOR.validate_source_references(root, catalogs, include_app=True)

            shell.write_text(json.dumps({"strings": {"First\nLine": {}, "Second": {}, "Visible": {}}}), encoding="utf-8")
            core = resource_root / "Core.xcstrings"
            core.write_text(json.dumps({"strings": {"Untitled folder": {}}}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "Untitled bookmark"):
                VALIDATOR.validate_source_references(root, catalogs, include_app=True)

    def test_rejects_direct_swiftui_text_when_hebrew_catalog_translation_exists(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Sources/ArcusisBrowser/ExampleView.swift"
            source.parent.mkdir(parents=True)
            source.write_text('Text("Translated footer")\n', encoding="utf-8")
            catalog_path = root / "Sources/BrowserCore/Resources/Settings.xcstrings"
            catalog_path.parent.mkdir(parents=True)
            catalog_path.write_text(
                json.dumps({"strings": {"Translated footer": {
                    "localizations": {"he": unit("כותרת תחתונה מתורגמת")}
                }}}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "unlocalized Text.*Translated footer"):
                VALIDATOR.validate_source_references(root, [catalog_path], include_app=True)

    def test_rejects_direct_accessibility_strings_when_hebrew_translation_exists(self):
        examples = (
            ('.help("Translated tooltip")', "help", "Translated tooltip"),
            ('.accessibilityLabel("Translated label")', "accessibilityLabel", "Translated label"),
            ('.accessibilityHint("Translated hint")', "accessibilityHint", "Translated hint"),
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Sources/ArcusisBrowser/ExampleView.swift"
            source.parent.mkdir(parents=True)
            catalog_path = root / "Sources/BrowserCore/Resources/Settings.xcstrings"
            catalog_path.parent.mkdir(parents=True)
            catalog_path.write_text(json.dumps({"strings": {
                key: {"localizations": {"he": unit("תרגום")}}
                for _, _, key in examples
            }}), encoding="utf-8")

            for swift, modifier, key in examples:
                source.write_text("Text(\"Example\")" + swift + "\n", encoding="utf-8")
                with self.subTest(modifier=modifier):
                    with self.assertRaisesRegex(ValueError, f"unlocalized {modifier}.*{key}"):
                        VALIDATOR.validate_source_references(root, [catalog_path], include_app=True)


if __name__ == "__main__":
    unittest.main()
