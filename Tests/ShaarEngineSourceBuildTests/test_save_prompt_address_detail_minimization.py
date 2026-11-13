# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Limit address details sent to the native save prompt."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0066-shaar-save-prompts.patch"


class SavePromptAddressDetailMinimizationTests(unittest.TestCase):
    def test_address_detail_omits_contact_fields(self):
        source = PATCH.read_text()
        start = source.index(
            "diff --git a/chrome/browser/ui/autofill/chrome_autofill_client.cc"
        )
        address_hook = source[start:]
        start = address_hook.index("std::string detail;")
        end = address_hook.index("auto decision = base::BindOnce(", start)
        detail_builder = address_hook[start:end]

        for field in ("NAME_FULL", "ADDRESS_HOME_LINE1", "ADDRESS_HOME_CITY"):
            with self.subTest(field=field):
                self.assertIn(f"append_field({field})", detail_builder)
        self.assertEqual(detail_builder.count("append_field("), 3)
        self.assertNotIn("EMAIL_ADDRESS", detail_builder)
        self.assertNotIn("PHONE_HOME_WHOLE_NUMBER", detail_builder)


if __name__ == "__main__":
    unittest.main()
