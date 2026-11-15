# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/devtools/shaar_devtools.cc"


class TrustedInputCaptureLeaseRetryTests(unittest.TestCase):
    def test_transient_capture_lease_overlap_retries_with_a_bounded_wait(self):
        source = SOURCE.read_text()
        trusted_input = source[
            source.index("class ProbeTrustedInput"):
            source.index("struct ProbeCaptureLeaseRegistry")
        ]

        self.assertIn("kProbeCaptureLeaseWait = base::Seconds(2)", source)
        self.assertIn("kProbeCaptureLeaseRetry = base::Milliseconds(25)", source)
        self.assertIn("TryStartCapture();", trusted_input)
        self.assertIn("StartHiddenProbeCapture(contents)", trusted_input)
        self.assertIn("&ProbeTrustedInput::TryStartCapture", trusted_input)
        self.assertIn("&ProbeTrustedInput::OnLeaseTimeout", trusted_input)
        self.assertIn('Fail("capture lease wait timed out")', trusted_input)


if __name__ == "__main__":
    unittest.main()
