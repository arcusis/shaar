"""The save-prompt probe only passes after each fixture form reaches its POST handler."""

import http.client
import importlib.util
from pathlib import Path
import threading
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


if __name__ == "__main__":
    unittest.main()
