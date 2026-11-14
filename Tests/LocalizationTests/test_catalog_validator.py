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
from unittest.mock import patch


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
    def test_show_all_history_native_menu_has_hebrew_settings_copy(self):
        key = "Show All History"
        catalog = json.loads(
            (ROOT / "Sources/BrowserCore/Resources/Settings.xcstrings").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(
            catalog["strings"][key]["localizations"]["he"]["stringUnit"]["value"],
            "הצגת כל ההיסטוריה",
        )
        source = (ROOT / "Sources/ArcusisBrowser/NativeBrowserHost.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn('add(.history, "Show All History", to: history)', source)

    def test_hebrew_bluetooth_permission_copy_uses_natural_passkey_wording(self):
        path = ROOT / "Resources/Localizations/InfoPlist.xcstrings"
        strings = json.loads(path.read_text(encoding="utf-8"))["strings"]
        value = strings["NSBluetoothAlwaysUsageDescription"]["localizations"]["he"][
            "stringUnit"
        ]["value"]
        self.assertEqual(
            value,
            "אתרים שתאשרו יוכלו להתחבר להתקני Bluetooth, כגון מפתחות אבטחה וטלפונים שמשמשים לכניסה באמצעות מפתח גישה.",
        )
    def test_window_navigation_native_menu_has_hebrew_copy(self):
        expected = {"Next Window": "החלון הבא", "Previous Window": "החלון הקודם"}
        for table in ("Shell", "Settings"):
            with self.subTest(table=table):
                catalog = json.loads(
                    (ROOT / f"Sources/BrowserCore/Resources/{table}.xcstrings").read_text(
                        encoding="utf-8"
                    )
                )
                for key, translation in expected.items():
                    self.assertEqual(
                        catalog["strings"][key]["localizations"]["he"]["stringUnit"]["value"],
                        translation,
                    )
        source = (ROOT / "Sources/ArcusisBrowser/NativeBrowserHost.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn('add(.nextWindow, "Next Window", to: window)', source)
        self.assertIn('add(.previousWindow, "Previous Window", to: window)', source)

    def test_site_action_failure_uses_localized_recovery_copy(self):
        key = "Could not complete the site action. Try again."
        catalog = json.loads(
            (ROOT / "Sources/BrowserCore/Resources/Shell.xcstrings").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(
            catalog["strings"][key]["localizations"]["he"]["stringUnit"]["value"],
            "לא ניתן להשלים את הפעולה באתר. כדאי לנסות שוב.",
        )
        source = (ROOT / "Sources/ArcusisBrowser/DevelopmentModeButton.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            'engine.reportNotice(ShellL10n.string("Could not complete the site action. Try again."))',
            source,
        )
    def test_enter_full_screen_native_menu_has_hebrew_copy(self):
        key = "Enter Full Screen"
        for table in ("Shell", "Settings"):
            with self.subTest(table=table):
                catalog = json.loads(
                    (ROOT / f"Sources/BrowserCore/Resources/{table}.xcstrings").read_text(
                        encoding="utf-8"
                    )
                )
                self.assertEqual(
                    catalog["strings"][key]["localizations"]["he"]["stringUnit"]["value"],
                    "כניסה למסך מלא",
                )
        source = (ROOT / "Sources/ArcusisBrowser/NativeBrowserHost.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn('add(.fullScreen, "Enter Full Screen", to: view)', source)

    def test_connected_agents_two_plural_uses_hebrew_dual_form(self):
        catalog = json.loads(
            (ROOT / "Sources/BrowserCore/Resources/Shell.xcstrings").read_text(
                encoding="utf-8"
            )
        )
        two = catalog["strings"]["%d connected agents"]["localizations"]["he"][
            "variations"
        ]["plural"]["two"]["stringUnit"]["value"]
        self.assertEqual(two, "שני סוכנים מחוברים")

    def test_clear_history_failure_uses_hebrew_recovery_copy(self):
        key = "Could not clear history. Try again."
        catalog = json.loads(
            (ROOT / "Sources/BrowserCore/Resources/Settings.xcstrings").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(
            catalog["strings"][key]["localizations"]["he"]["stringUnit"]["value"],
            "לא ניתן למחוק את ההיסטוריה. כדאי לנסות שוב.",
        )
        source = (ROOT / "Sources/ArcusisBrowser/BrowserSettingsView.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn('SettingsL10n.string("Could not clear history. Try again.")', source)
        self.assertNotIn('SettingsL10n.format("Could not clear history: %"', source)

    def validate(self, data):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Fixture.xcstrings"
            path.write_text(json.dumps(data), encoding="utf-8")
            VALIDATOR.validate_catalog(path)

    def test_main_rejects_symlinked_output_directory_without_touching_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "package"
            core = package / "Sources/BrowserCore/Resources"
            resources = package / "Resources/Localizations"
            core.mkdir(parents=True)
            resources.mkdir(parents=True)
            (core / "Core.xcstrings").write_text("{}", encoding="utf-8")
            target = root / "output-target"
            target.mkdir()
            marker = target / "en.lproj"
            marker.mkdir()
            (marker / "preserve.txt").write_text("preserve", encoding="utf-8")
            output_link = root / "output-link"
            output_link.symlink_to(target, target_is_directory=True)

            with patch.object(VALIDATOR.sys, "argv", ["compile-localizations.py", str(package), str(output_link)]), \
                    patch.object(VALIDATOR, "validate_catalog"), \
                    patch.object(VALIDATOR, "validate_source_references"), \
                    patch.object(VALIDATOR, "compile_native") as compile_native:
                with self.assertRaisesRegex(SystemExit, "output directory must not be a symlink"):
                    VALIDATOR.main()
                compile_native.assert_not_called()

            self.assertEqual((marker / "preserve.txt").read_text(encoding="utf-8"), "preserve")
    def test_browser_store_save_failure_uses_localized_recovery_copy(self):
        key = "Changes could not be saved. Try again."
        catalog = json.loads(
            (ROOT / "Sources/BrowserCore/Resources/Shell.xcstrings").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(
            catalog["strings"][key]["localizations"]["he"]["stringUnit"]["value"],
            "לא ניתן לשמור את השינויים. כדאי לנסות שוב.",
        )
        source = (ROOT / "Sources/ArcusisBrowser/BrowserStore.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn('ShellL10n.string("Changes could not be saved. Try again.")', source)
        self.assertNotIn('ShellL10n.format("Changes could not be saved. %@"', source)

    def test_library_mutation_failure_uses_localized_recovery_copy(self):
        key = "Could not update the Library. Try again."
        catalog = json.loads(
            (ROOT / "Sources/BrowserCore/Resources/Panels.xcstrings").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(
            catalog["strings"][key]["localizations"]["he"]["stringUnit"]["value"],
            "לא ניתן לעדכן את הספרייה. כדאי לנסות שוב.",
        )
        source = (ROOT / "Sources/ArcusisBrowser/BrowserEngine.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn('PanelsL10n.string("Could not update the Library. Try again.")', source)

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
    def test_inspector_section_disclosure_uses_direction_aware_chevron(self):
        source = (ROOT / "Sources/ArcusisBrowser/InspectorPanelComponents.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn('isCollapsed ? "chevron.forward" : "chevron.down"', source)

    def test_source_editor_menu_uses_direction_aware_disclosure(self):
        source = (ROOT / "Sources/ArcusisBrowser/InspectorActionsView.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn('Image(systemName: "chevron.forward")', source)

    def test_developer_page_action_failures_use_localized_recovery_copy(self):
        source = (ROOT / "Sources/ArcusisBrowser/DevelopmentModeButton.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn("engine.reportNotice(action.failureNotice())", source)
        shell = json.loads(
            (ROOT / "Sources/BrowserCore/Resources/Shell.xcstrings").read_text(
                encoding="utf-8"
            )
        )
        translation = shell["strings"]["Could not complete the %@ action. Try again."][
            "localizations"]["he"]["stringUnit"]["value"]
        self.assertEqual(translation, "לא ניתן להשלים את הפעולה %@. כדאי לנסות שוב.")

    def test_extension_execution_failure_uses_hebrew_shell_copy(self):
        source = (ROOT / "Sources/ArcusisBrowser/BrowserEngine.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            'ShellL10n.string("Could not run this extension. Try again.")', source
        )
        shell = json.loads(
            (ROOT / "Sources/BrowserCore/Resources/Shell.xcstrings").read_text(
                encoding="utf-8"
            )
        )
        translation = shell["strings"]["Could not run this extension. Try again."][
            "localizations"]["he"]["stringUnit"]["value"]
        self.assertEqual(translation, "לא ניתן להפעיל את התוסף. כדאי לנסות שוב.")

    def test_paste_match_style_native_menu_has_hebrew_catalog_entry(self):
        key = "Paste and Match Style"
        catalog = json.loads(
            (ROOT / "Sources/BrowserCore/Resources/Shell.xcstrings").read_text(encoding="utf-8")
        )
        self.assertEqual(
            catalog["strings"][key]["localizations"]["he"]["stringUnit"]["value"],
            "הדבקה והתאמת סגנון",
        )
        source = (ROOT / "Sources/ArcusisBrowser/NativeBrowserHost.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn('addStandard("Paste and Match Style"', source)

    def test_profile_creation_failure_uses_hebrew_recovery_copy(self):
        source = (ROOT / "Sources/ArcusisBrowser/ProfileOnboardingModel.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn('SettingsL10n.string("Could not create this profile. Try again.")', source)
        settings = json.loads(
            (ROOT / "Sources/BrowserCore/Resources/Settings.xcstrings").read_text(
                encoding="utf-8"
            )
        )
        translation = settings["strings"]["Could not create this profile. Try again."][
            "localizations"]["he"]["stringUnit"]["value"]
        self.assertEqual(translation, "לא ניתן ליצור את הפרופיל. כדאי לנסות שוב.")

    def test_rejects_null_catalog_and_localization_maps_cleanly(self):
        for data in (None, {"sourceLanguage": "en", "strings": {"x": None}},
                     {"sourceLanguage": "en", "strings": {"x": {"localizations": None}}}):
            with self.subTest(data=data), self.assertRaisesRegex(ValueError, "catalog|entry|map"):
                self.validate(data)

    def test_rejects_duplicate_string_catalog_keys(self):
        entry = catalog("Open %@", "פתיחה של %@")["strings"]["Open %@"]
        key = json.dumps("Open %@")
        encoded_entry = json.dumps(entry, ensure_ascii=False)
        source = (
            '{"sourceLanguage":"en","strings":{'
            + f"{key}:{encoded_entry},{key}:{encoded_entry}"
            + "}}"
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Fixture.xcstrings"
            path.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "duplicate JSON key 'Open %@'"):
                VALIDATOR.validate_catalog(path)

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
    def test_split_pane_loading_uses_hebrew_catalog_copy(self):
        source = (ROOT / "Sources/ArcusisBrowser/SplitPageView.swift").read_text(encoding="utf-8")
        self.assertIn('ProgressView(ShellL10n.string("Loading profile…"))', source)
        self.assertNotIn('ProgressView("Loading profile…")', source)
        catalog = json.loads((ROOT / "Sources/BrowserCore/Resources/Shell.xcstrings").read_text(encoding="utf-8"))
        hebrew = catalog["strings"]["Loading profile…"]["localizations"]["he"]["stringUnit"]["value"]
        self.assertEqual(hebrew, "הפרופיל נטען…")

    def test_folder_name_accessibility_uses_panels_catalog(self):
        source = (ROOT / "Sources/ArcusisBrowser/BrowserSidebar.swift").read_text(encoding="utf-8")
        self.assertIn('accessibilityLabel(PanelsL10n.string("Folder name"))', source)
        self.assertNotIn('accessibilityLabel(ShellL10n.string("Folder name"))', source)
        catalog = json.loads((ROOT / "Sources/BrowserCore/Resources/Panels.xcstrings").read_text(encoding="utf-8"))
        self.assertEqual(catalog["strings"]["Folder name"]["localizations"]["he"]["stringUnit"]["value"], "שם התיקייה")

    def test_recent_history_plural_describes_pages_opened_recently(self):
        catalog = json.loads((ROOT / "Sources/BrowserCore/Resources/Panels.xcstrings").read_text(encoding="utf-8"))
        forms = catalog["strings"]["%d recent pages"]["localizations"]["he"]["variations"]["plural"]
        self.assertEqual(forms["one"]["stringUnit"]["value"], "דף אחד שנפתח לאחרונה")
        self.assertEqual(forms["two"]["stringUnit"]["value"], "שני דפים שנפתחו לאחרונה")
        self.assertEqual(forms["other"]["stringUnit"]["value"], "%d דפים שנפתחו לאחרונה")

    def test_inspector_sanitized_url_placeholders_are_localized_in_ui(self):
        catalog = json.loads((ROOT / "Sources/BrowserCore/Resources/Inspector.xcstrings").read_text(encoding="utf-8"))
        entry = catalog["strings"]["[URL omitted]"]["localizations"]
        self.assertEqual(entry["he"]["stringUnit"]["value"], "כתובת URL הושמטה")
        l10n = (ROOT / "Sources/ArcusisBrowser/InspectorL10n.swift").read_text(encoding="utf-8")
        self.assertIn('"[URL omitted]", "Unavailable"', l10n)
        notes = (ROOT / "Sources/ArcusisBrowser/InspectorNotesView.swift").read_text(encoding="utf-8")
        self.assertIn("InspectorL10n.display(InspectorAIFormatter.url(note.context.url))", notes)
        actions = (ROOT / "Sources/ArcusisBrowser/InspectorSourceActions.swift").read_text(encoding="utf-8")
        self.assertIn("location = InspectorL10n.display(InspectorAIFormatter.url(source))", actions)

    def test_markup_byte_plural_uses_hebrew_byte_term(self):
        catalog = json.loads((ROOT / "Sources/BrowserCore/Resources/InspectorDetails.xcstrings").read_text(encoding="utf-8"))
        forms = catalog["strings"]["%d bytes of markup"]["localizations"]["he"]["variations"]["plural"]
        self.assertEqual(forms["one"]["stringUnit"]["value"], "בייט אחד של קוד סימון")
        self.assertEqual(forms["two"]["stringUnit"]["value"], "שני בייטים של קוד סימון")
        self.assertEqual(forms["other"]["stringUnit"]["value"], "%d בייטים של קוד סימון")

    def test_inspector_source_loader_errors_use_inspector_catalog(self):
        catalog = json.loads((ROOT / "Sources/BrowserCore/Resources/Inspector.xcstrings").read_text(encoding="utf-8"))
        expected = {
            "This source is no longer available.": "המקור הזה כבר אינו זמין.",
            "This source is no longer in the page resource tree.": "המקור הזה כבר אינו מופיע בעץ המשאבים של הדף.",
            "Source content is unavailable or exceeds 5 MiB.": "תוכן המקור אינו זמין או שגודלו חורג מ־5 MiB.",
        }
        source = (ROOT / "Sources/ArcusisBrowser/ShaarInspectorSourceLoader.swift").read_text(encoding="utf-8")
        for key, translation in expected.items():
            with self.subTest(key=key):
                self.assertEqual(catalog["strings"][key]["localizations"]["he"]["stringUnit"]["value"], translation)
                self.assertIn(f'InspectorL10n.string("{key}")', source)

    def test_bridge_english_single_download_keeps_numeric_one(self):
        path = ROOT / "Sources/BrowserCore/Resources/Bridge.xcstrings"
        data = json.loads(path.read_text(encoding="utf-8"))
        english_one = data["strings"]["%d active downloads"]["localizations"]["en"]
        value = english_one["variations"]["plural"]["one"]["stringUnit"]["value"]
        self.assertEqual(value, "Closing the browser will cancel 1 active download.")
        bridge = (ROOT / "Sources/ChromiumBridge/ChromiumBridge.mm").read_text(encoding="utf-8")
        self.assertEqual(bridge.count('Closing the browser will cancel 1 active download.'), 2)

    def test_library_import_summary_uses_hebrew_plural_categories(self):
        catalog = json.loads((ROOT / "Sources/BrowserCore/Resources/Panels.xcstrings").read_text(encoding="utf-8"))["strings"]
        source = (ROOT / "Sources/ArcusisBrowser/BrowserImportPreviewView.swift").read_text(encoding="utf-8")
        self.assertIn("BrowserImportPreviewCounts.summary(", source)
        for key, dual in (("%d bookmark", "שתי סימניות"),
                          ("%d history entry", "שני פריטי היסטוריה")):
            with self.subTest(key=key):
                self.assertEqual(set(catalog[key]["localizations"]["he"]["variations"]["plural"]), {"one", "two", "other"})
                self.assertEqual(catalog[key]["localizations"]["he"]["variations"]["plural"]["two"]["stringUnit"]["value"], dual)

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
    def test_inspector_disclosure_chevrons_follow_reading_direction(self):
        for name in ("InspectorActionsView.swift", "InspectorPanel.swift", "InspectorPanelComponents.swift"):
            with self.subTest(name=name):
                source = (ROOT / "Sources/ArcusisBrowser" / name).read_text(encoding="utf-8")
                self.assertIn("chevron.forward", source)
                self.assertNotIn('"chevron.right"', source)

    def test_inspector_markup_size_uses_hebrew_byte_term_in_all_plural_forms(self):
        strings = json.loads(
            (ROOT / "Sources/BrowserCore/Resources/InspectorDetails.xcstrings").read_text(
                encoding="utf-8"))["strings"]
        forms = strings["%d bytes of markup"]["localizations"]["he"]["variations"]["plural"]
        self.assertEqual(forms["one"]["stringUnit"]["value"], "בייט אחד של קוד סימון")
        self.assertEqual(forms["two"]["stringUnit"]["value"], "שני בייטים של קוד סימון")
        self.assertEqual(forms["other"]["stringUnit"]["value"], "%d בייטים של קוד סימון")

    def test_inspector_copy_backend_failures_use_hebrew_recovery_copy(self):
        key = "Could not copy the selected element. Try again."
        catalog = json.loads((ROOT / "Sources/BrowserCore/Resources/Inspector.xcstrings").read_text(encoding="utf-8"))["strings"]
        self.assertEqual(catalog[key]["localizations"]["he"]["stringUnit"]["value"], "לא ניתן להעתיק את הרכיב שנבחר. כדאי לנסות שוב.")
        source = (ROOT / "Sources/ArcusisBrowser/InspectorAICopyModel.swift").read_text(encoding="utf-8")
        self.assertEqual(source.count("Self.failureMessage(for: error)"), 3)

    def test_developer_simulation_runtime_errors_use_hebrew_recovery_copy(self):
        key = "Could not apply developer settings. Try again."
        catalog = json.loads((ROOT / "Sources/BrowserCore/Resources/InspectorTools.xcstrings").read_text(encoding="utf-8"))["strings"]
        self.assertEqual(catalog[key]["localizations"]["he"]["stringUnit"]["value"], "לא ניתן להחיל את הגדרות הפיתוח. כדאי לנסות שוב.")
        source = (ROOT / "Sources/ArcusisBrowser/DeveloperPageModel.swift").read_text(encoding="utf-8")
        self.assertIn("Self.failureMessage(for: error)", source)

    def test_inspector_source_action_failures_use_hebrew_recovery_copy(self):
        key = "Could not get the source details. Try again."
        catalog = json.loads((ROOT / "Sources/BrowserCore/Resources/Inspector.xcstrings").read_text(encoding="utf-8"))["strings"]
        self.assertEqual(catalog[key]["localizations"]["he"]["stringUnit"]["value"], "לא ניתן לקבל את פרטי המקור. כדאי לנסות שוב.")
        source = (ROOT / "Sources/ArcusisBrowser/InspectorSourceActions.swift").read_text(encoding="utf-8")
        self.assertEqual(source.count("Self.failureMessage(for: error)"), 2)

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

    def test_rejects_direct_swiftui_control_titles_with_hebrew_catalog_translations(self):
        controls = ("Button", "Label", "Menu", "Picker", "SecureField", "TextField", "Toggle")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Sources/ArcusisBrowser/ExampleView.swift"
            source.parent.mkdir(parents=True)
            catalog_path = root / "Sources/BrowserCore/Resources/Settings.xcstrings"
            catalog_path.parent.mkdir(parents=True)
            keys = {f"Translated {control}": {
                "localizations": {"he": unit(f"{control} מתורגם")}
            } for control in controls}
            catalog_path.write_text(json.dumps({"strings": keys}), encoding="utf-8")

            for control in controls:
                key = f"Translated {control}"
                source.write_text(f'{control}("{key}")\n', encoding="utf-8")
                with self.subTest(control=control):
                    with self.assertRaisesRegex(
                        ValueError, f"unlocalized {control} title.*{key}"
                    ):
                        VALIDATOR.validate_source_references(root, [catalog_path], include_app=True)

    def test_rejects_direct_swiftui_text_when_hebrew_plural_catalog_exists(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Sources/ArcusisBrowser/ExampleView.swift"
            source.parent.mkdir(parents=True)
            source.write_text('Text("%d week ago")\n', encoding="utf-8")
            catalog_path = root / "Sources/BrowserCore/Resources/Panels.xcstrings"
            catalog_path.parent.mkdir(parents=True)
            catalog_path.write_text(json.dumps({"strings": {
                "%d week ago": {"localizations": {"he": {"variations": {"plural": {
                    "one": unit("לפני שבוע"),
                    "two": unit("לפני שבועיים"),
                    "other": unit("לפני %d שבועות"),
                }}}}}
            }}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "unlocalized Text.*%d week ago"):
                VALIDATOR.validate_source_references(root, [catalog_path], include_app=True)

    def test_folder_name_field_uses_its_shell_catalog_translation(self):
        source = (ROOT / "Sources/ArcusisBrowser/BrowserSidebar.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn('ShellL10n.string("Untitled")', source)

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
    def test_source_reference_scanner_ignores_wrapper_calls_in_comments(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Sources/BrowserCore/Example.swift"
            source.parent.mkdir(parents=True)
            source.write_text(
                '// BrowserLocalization.string("Missing key")\n'
                '/* outer /* ShellL10n.text("Also missing") */ still a comment */\n',
                encoding="utf-8",
            )
            catalog_path = root / "Sources/BrowserCore/Resources/Core.xcstrings"
            catalog_path.parent.mkdir(parents=True)
            catalog_path.write_text(json.dumps({"strings": {}}), encoding="utf-8")
            VALIDATOR.validate_source_references(root, [catalog_path])

    def test_rejects_direct_swiftui_control_titles_when_hebrew_translation_exists(self):
        examples = (
            ('Menu("Translated menu") {}', "Menu", "Translated menu"),
            ('Picker("Translated picker", selection: $selection) {}', "Picker", "Translated picker"),
            ('Toggle("Translated toggle", isOn: $enabled)', "Toggle", "Translated toggle"),
            ('Section("Translated section") {}', "Section", "Translated section"),
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

            for swift, control, key in examples:
                source.write_text(swift + "\n", encoding="utf-8")
                with self.subTest(control=control):
                    with self.assertRaisesRegex(ValueError, f"unlocalized {control}.*{key}"):
                        VALIDATOR.validate_source_references(root, [catalog_path], include_app=True)

if __name__ == "__main__":
    unittest.main()
