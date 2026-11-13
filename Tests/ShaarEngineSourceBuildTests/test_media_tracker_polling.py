# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/media/shaar_media.cc"


class MediaTrackerPollingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text()
        start = cls.source.index("class MediaTracker final")
        end = cls.source.index("MediaTrackerPtr CreateMediaTracker", start)
        cls.tracker = cls.source[start:end]

    def test_media_tracker_uses_one_shot_timer(self):
        self.assertIn("base::OneShotTimer timer_;", self.tracker)
        self.assertNotIn("base::RepeatingTimer timer_;", self.tracker)

    def test_completed_samples_back_off_by_playback_state(self):
        self.assertIn(
            'playback && *playback == "playing" ? base::Seconds(2)', self.tracker
        )
        self.assertIn(": base::Seconds(10)", self.tracker)
        self.assertIn("this, &MediaTracker::Refresh);", self.tracker)

    def test_playback_observers_replace_any_pending_sample(self):
        self.assertRegex(
            self.tracker,
            re.compile(
                r"void MediaStartedPlaying\(.*?override\s*\{\s*"
                r"timer_\.Stop\(\);\s*Refresh\(\);\s*\n  \}",
                re.DOTALL,
            ),
        )
        self.assertRegex(
            self.tracker,
            re.compile(
                r"void MediaStoppedPlaying\(.*?override\s*\{\s*"
                r"timer_\.Stop\(\);\s*Refresh\(\);\s*\n  \}",
                re.DOTALL,
            ),
        )


if __name__ == "__main__":
    unittest.main()
