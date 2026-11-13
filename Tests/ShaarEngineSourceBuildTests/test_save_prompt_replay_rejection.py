# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Reject duplicate decisions after a save prompt has completed."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptReplayRejectionTests(unittest.TestCase):
    def test_finish_removes_pending_id_before_callback_and_replay_is_not_found(self):
        source = SOURCE.read_text()
        start = source.index("void Finish(")
        end = source.index("void EmitDismiss(", start)
        finish = source[start:end]
        self.assertLess(
            finish.index("Pending().erase(found)"),
            finish.index("callback).Run(choice)"),
        )

        start = source.index("int TakeDecision(")
        end = source.index("bool ProfileOwnsContents(", start)
        decision = source[start:end]
        missing = decision.index("found == Pending().end()")
        not_found = decision.index("*error = SHAAR_NOT_FOUND", missing)
        self.assertLess(missing, not_found)


if __name__ == "__main__":
    unittest.main()
