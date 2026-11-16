# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""The save-prompt probe only passes after each fixture form reaches its POST handler."""

import http.client
import importlib.util
import json
from pathlib import Path
import sqlite3
import threading
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "shaar_save_prompt_probe", ROOT / "scripts" / "test-shaar-save-prompt.py"
)
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class SavePromptFixtureSubmissionTests(unittest.TestCase):
    def setUp(self):
        self.server = PROBE.FixtureServer(("127.0.0.1", 0), PROBE.Fixture)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def test_submit_button_stays_in_normal_flow_below_form_fields(self):
        self.assertNotIn("style=", PROBE.BUTTON)

    def test_receipt_tracks_password_card_and_address_posts_by_referer(self):
        for form in ("/password", "/card", "/address"):
            connection = http.client.HTTPConnection(*self.server.server_address)
            connection.request(
                "POST", "/saved", body=b"fixture=1",
                headers={"Referer": f"http://127.0.0.1:{self.server.server_port}{form}"},
            )
            response = connection.getresponse()
            response.read()
            self.assertEqual(response.status, 200, form)
            connection.close()

        self.assertEqual(self.server.submitted_forms(), ["/address", "/card", "/password"])

    def test_unrelated_referer_does_not_count_as_a_fixture_submission(self):
        self.server.record_submission("http://127.0.0.1:8000/other")
        self.assertEqual(self.server.submitted_forms(), [])

    def test_prompt_screenshots_are_copied_out_of_the_temporary_probe_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "probe"
            source.mkdir()
            for name in PROBE.PROMPT_NAMES:
                (source / f"save-prompt-{name}.png").write_bytes(name.encode())

            receipt = root / "receipt.json"
            english_dir = PROBE.screenshot_directory(receipt, "en")
            hebrew_dir = PROBE.screenshot_directory(receipt, "he")
            english = PROBE.copy_prompt_screenshots(source, english_dir)
            hebrew = PROBE.copy_prompt_screenshots(source, hebrew_dir)

            expected = {name: str(english_dir / f"save-prompt-{name}.png")
                        for name in PROBE.PROMPT_NAMES}
            self.assertEqual(english, expected)
            self.assertEqual(
                set(hebrew), set(PROBE.PROMPT_NAMES))
            self.assertNotEqual(english["password-save"], hebrew["password-save"])
            self.assertEqual(
                (english_dir / "save-prompt-address-dismiss.png").read_bytes(),
                b"address-dismiss")
            with self.assertRaises(ValueError):
                PROBE.screenshot_directory(receipt, "fr")

    def test_action_submission_counts_distinguish_each_choice(self):
        for _ in range(2):
            self.server.record_submission("http://127.0.0.1:8000/card")
        self.server.record_submission("http://127.0.0.1:8000/address")
        self.assertEqual(
            self.server.submission_counts(), {"/card": 2, "/address": 1})

    def test_save_offer_scenarios_keep_the_selected_browser_context(self):
        source = (ROOT / "Sources" / "ShaarVerification" / "ShaarSavePromptProbe.swift").read_text()
        self.assertIn("for scenario in scenarios", source)
        self.assertIn("let caseContext = try freshContext(host: host, from: context)", source)

    def test_receipt_reports_save_preferences_from_uuid_profiles(self):
        with tempfile.TemporaryDirectory() as temporary:
            data_root = Path(temporary) / "Chromium"
            profile = data_root / "Profile c95c57fb-72b2-4a99-b242-745585bbc06b"
            profile.mkdir(parents=True)
            (profile / "Preferences").write_text(json.dumps({
                "credentials_enable_service": True,
                "autofill": {"profile_enabled": True, "credit_card_enabled": True},
            }))

            self.assertEqual(PROBE.profile_autofill_preferences(data_root), [{
                "profile": "Profile c95c57fb-72b2-4a99-b242-745585bbc06b",
                "credentialsEnableService": True,
                "autofillProfileEnabled": True,
                "autofillCreditCardEnabled": True,
            }])

    def test_password_store_diagnostic_matches_saved_credential_to_profile(self):
        with tempfile.TemporaryDirectory() as temporary:
            data_root = Path(temporary) / "Chromium"
            profile_id = "c95c57fb-72b2-4a99-b242-745585bbc06b"
            database = data_root / f"Profile {profile_id}" / "Login Data"
            database.parent.mkdir(parents=True, exist_ok=True)
            connection = sqlite3.connect(database)
            connection.execute(
                """CREATE TABLE logins (
                     username_value TEXT, origin_url TEXT,
                     blacklisted_by_user INTEGER, password_value BLOB
                   )""")
            connection.execute(
                """INSERT INTO logins VALUES (
                     'parity-user', 'http://127.0.0.1:8000/', 0, X'010203'
                   )""")
            connection.commit()
            connection.close()

            evidence = PROBE.profile_password_evidence(
                data_root, "parity-user", "http://127.0.0.1:8000/", profile_id)
            self.assertEqual(len(evidence), 1)
            self.assertTrue(evidence[0]["fixtureCredentialStored"])
            self.assertTrue(evidence[0]["matchesSaveProfile"])
            self.assertTrue(PROBE.saved_in_profile(evidence, profile_id))
            self.assertNotIn("parity-secret", str(evidence))

    def test_password_store_diagnostic_uses_save_row_after_dismiss_row(self):
        profile_id = "c95c57fb-72b2-4a99-b242-745585bbc06b"
        self.assertEqual(PROBE.password_save_profile_id([
            {"name": "password-dismiss"},
            {"name": "password", "saveProfileID": profile_id},
        ]), profile_id)

    def test_card_and_address_fixtures_include_valid_autocomplete_data(self):
        swift = (ROOT / "Sources" / "ShaarVerification" / "ShaarSavePromptProbe.swift").read_text()
        card_number = "4111111111111111"
        digits = [int(digit) for digit in card_number]
        doubled = [digit * 2 if index % 2 == 1 else digit
                   for index, digit in enumerate(reversed(digits))]
        luhn_total = sum(digit - 9 if digit > 9 else digit for digit in doubled)
        self.assertEqual(luhn_total % 10, 0)
        self.assertIn(f'("card-number", "{card_number}")', swift)
        self.assertIn('("card-exp-month", "12")', swift)
        self.assertIn('("card-exp-year", Self.cardExpiryYear(relativeTo: .now))', swift)
        self.assertIn('"card-name", "Probe ', swift)
        self.assertIn('"address-name", "Probe ', swift)
        self.assertIn('"address-street", "1 ', swift)
        self.assertIn('"address-city", "Mountain View"', swift)
        self.assertIn('"address-postal", "94043"', swift)
        self.assertIn('"address-country", "United States"', swift)
        fixture = (ROOT / "scripts" / "test-shaar-save-prompt.py").read_text()
        self.assertGreaterEqual(fixture.count('method="post" autocomplete="on"'), 4)
        for autocomplete in (
            "cc-name", "cc-number", "cc-exp-month", "cc-exp-year", "name",
            "street-address", "address-level2", "address-level1", "postal-code",
            "country-name",
        ):
            with self.subTest(autocomplete=autocomplete):
                self.assertIn(f'autocomplete="{autocomplete}"', fixture)
        for field_id in (
            "card-name", "card-number", "card-exp-month", "card-exp-year",
            "address-name", "address-street", "address-city", "address-postal",
            "address-country",
        ):
            with self.subTest(field_id=field_id):
                self.assertIn(f'<label for="{field_id}">', fixture)

    def test_receipt_keeps_only_known_trusted_input_failure_stages(self):
        output = (
            "Trusted probe text: trusted input failed at target unavailable before text commit\n"
            "Trusted probe text: trusted input failed at render surface unavailable\n"
            "Trusted probe text: trusted input failed at engine request rejected\n"
            "Trusted probe text: trusted input failed at user supplied secret\n"
        )
        self.assertEqual(
            PROBE.trusted_input_failure_stages(output),
            ["target unavailable before text commit", "render surface unavailable",
             "engine request rejected"],
        )

    def test_receipt_keeps_redacted_trusted_text_field_diagnostics(self):
        diagnostics = PROBE.safe_trusted_text_diagnostics({
            "trustedTextDiagnostics": [{
                "valuesEntered": True,
                "fields": [{
                    "id": "password", "present": True, "valueMatches": False,
                    "valueLength": 13, "focused": True, "value": "secret-value",
                }],
                "activeElementIsInput": True,
                "activeInputType": "password",
                "unexpected": "discarded",
            }],
            "unexpected": "discarded",
        })

        self.assertEqual(diagnostics, [{
            "valuesEntered": True,
            "fields": [{
                "id": "password", "present": True, "valueMatches": False,
                "valueLength": 13, "focused": True,
            }],
            "activeElementIsInput": True,
            "activeInputType": "password",
        }])

    def test_profile_receipt_keeps_only_save_offer_preference_booleans(self):
        with tempfile.TemporaryDirectory() as temporary:
            profile = Path(temporary) / "Chromium" / "Default"
            profile.mkdir(parents=True)
            (profile / "Preferences").write_text(
                '{"credentials_enable_service":true,"autofill":'
                '{"profile_enabled":false,"credit_card_enabled":true},'
                '"homepage":"https://example.invalid"}'
            )

            self.assertEqual(PROBE.profile_autofill_preferences(profile.parent), [{
                "profile": "Default",
                "credentialsEnableService": True,
                "autofillProfileEnabled": False,
                "autofillCreditCardEnabled": True,
            }])

    def test_profile_receipt_detects_only_the_matching_saved_fixture_login(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "Chromium"
            profile_id = "00000000-0000-0000-0000-000000000001"
            for name, username in [
                ("Default", "parity-user"),
                (f"Profile {profile_id}", "parity-user"),
            ]:
                profile = root / name
                profile.mkdir(parents=True)
                database = sqlite3.connect(profile / "Login Data")
                database.execute(
                    "CREATE TABLE logins (origin_url TEXT, username_value TEXT, "
                    "blacklisted_by_user INTEGER, password_value BLOB)"
                )
                database.executemany(
                    "INSERT INTO logins VALUES (?, ?, ?, ?)",
                    [
                        ("http://127.0.0.1:8000/password", username, 0, b"secret"),
                        ("http://127.0.0.1:8001/", username, 0, b"secret"),
                        ("http://127.0.0.1:8000/", "blocked-user", 1, b"secret"),
                    ],
                )
                database.commit()
                database.close()

            evidence = PROBE.profile_password_evidence(
                root, "parity-user", "http://127.0.0.1:8000/", profile_id
            )

            self.assertEqual([entry["matchesSaveProfile"] for entry in evidence],
                             [False, True])
            self.assertTrue(PROBE.saved_in_profile(evidence, profile_id))
            self.assertFalse(PROBE.saved_in_profile(evidence, "different-profile"))
            self.assertNotIn("secret", repr(evidence))


if __name__ == "__main__":
    unittest.main()
