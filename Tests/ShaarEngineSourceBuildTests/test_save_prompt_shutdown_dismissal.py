# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Avoid emitting save-prompt dismissals after engine shutdown."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptShutdownDismissalTests(unittest.TestCase):
    def test_dismissal_checks_engine_readiness_before_payload_or_emission(self):
        source = SOURCE.read_text()
        start = source.index("void EmitDismiss(")
        end = source.index("void Expire(", start)
        dismiss = source[start:end]

        readiness = dismiss.index("lifecycle::EngineIsReady(pending.engine)")
        return_if_stopped = dismiss.index("return;", readiness)
        event = dismiss.index("shaar::EmitEvent(", readiness)
        self.assertLess(readiness, return_if_stopped)
        self.assertLess(return_if_stopped, event)


if __name__ == "__main__":
    unittest.main()
