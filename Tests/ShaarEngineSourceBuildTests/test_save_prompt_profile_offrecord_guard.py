# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Reject private profiles when resolving save-prompt decision ownership."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptProfileOffTheRecordGuardTests(unittest.TestCase):
    def test_profile_ownership_rejects_off_the_record_profile_handles(self):
        source = SOURCE.read_text()
        start = source.index("bool ProfileOwnsContents(")
        end = source.index("}  // namespace", start)
        ownership = source[start:end]

        profile = ownership.index("Profile* profile =")
        off_the_record = ownership.index("!profile->IsOffTheRecord()", profile)
        exact_context = ownership.index(
            "profile == Profile::FromBrowserContext(contents->GetBrowserContext())",
            off_the_record,
        )
        self.assertLess(profile, off_the_record)
        self.assertLess(off_the_record, exact_context)


if __name__ == "__main__":
    unittest.main()
