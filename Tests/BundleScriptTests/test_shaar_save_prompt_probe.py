"""The save-prompt probe only passes after each fixture form reaches its POST handler."""

import http.client
import importlib.util
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
