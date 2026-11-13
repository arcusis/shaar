# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Check save-prompt profile ownership before parsing or consuming a decision."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptProfileOwnershipOrderTests(unittest.TestCase):
    def test_wrong_profile_is_rejected_before_payload_and_pending_lookup(self):
        source = SOURCE.read_text()
        start = source.index("shaar_error_code CompleteDecision(")
        end = source.index("}  // namespace shaar::save_prompts", start)
        complete = source[start:end]

        ownership = complete.index(
            "ProfileOwnsContents(context, engine, scope, contents)"
        )
        wrong_profile = complete.index("SHAAR_WRONG_PROFILE", ownership)
        parse = complete.index("ParseArguments(bytes)", ownership)
        take = complete.index("TakeDecision(engine, contents", ownership)
        self.assertLess(ownership, wrong_profile)
        self.assertLess(wrong_profile, parse)
        self.assertLess(parse, take)


if __name__ == "__main__":
    unittest.main()
