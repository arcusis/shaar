# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from dataclasses import replace
from pathlib import Path
import random
import sys
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import release_feed


class ReleaseFeedPropertyTests(unittest.TestCase):
    def test_seeded_appcasts_round_trip_and_reject_mismatched_contracts(self):
        original = release_feed.load_config()
        for seed in (0x334, 0x5A17, 0xC0FFEE):
            generator = random.Random(seed)
            for index in range(64):
                with self.subTest(seed=seed, case=index):
                    config = replace(original, bundle_version=".".join(str(generator.randrange(100)) for _ in range(3)),
                                     build_version=generator.randrange(1, 1_000_000))
                    length = generator.randrange(1, 10_000_000)
                    text = release_feed.render_appcast(config, length=length, signature="fixture-signature",
                                                       notes_html=f"<li>Case {index}</li>",
                                                       pub_date="Sun, 01 Nov 2026 12:00:00 GMT")
                    item = release_feed.validate_appcast(text, config)
                    self.assertEqual((item.bundle_version, item.build_version, item.length, item.url),
                                     (config.bundle_version, config.build_version, length, config.zip_url))
                    root = ET.fromstring(text)
                    enclosure = root.find("./channel/item/enclosure")
                    enclosure.set("url", "https://example.invalid/other.zip")
                    with self.assertRaises(release_feed.ReleaseError):
                        release_feed.validate_appcast(ET.tostring(root, encoding="unicode"), config)
                    enclosure.set("url", config.zip_url)
                    enclosure.set("length", generator.choice(["0", "-1", "1.5", "NaN", ""]))
                    with self.assertRaises(release_feed.ReleaseError):
                        release_feed.parse_appcast(ET.tostring(root, encoding="unicode"))


if __name__ == "__main__":
    unittest.main()
