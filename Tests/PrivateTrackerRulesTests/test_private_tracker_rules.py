# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("private_tracker_rules", ROOT / "scripts/update-private-trackers.py")
RULES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RULES)


class PrivateTrackerRulesTests(unittest.TestCase):
    def test_output_writer_rejects_symlink_without_overwriting_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "outside.json"
            target.write_text("preserve this", encoding="utf-8")
            output = root / "rules.json"
            output.symlink_to(target)

            with self.assertRaisesRegex(ValueError, "tracker rules output must not be a symlink"):
                RULES.write_rules(output, {"domains": ["example.test"]})

            self.assertEqual(target.read_text(encoding="utf-8"), "preserve this")

    def test_only_complete_domain_rules_are_used(self):
        text = "\n".join((
            "! comment", "||analytics.example^", "||tracker.example^$third-party",
            "@@||allowed.example^", "||conditional.example^$domain=site.example",
            "||path.example/collect", "||wild-*.example^", "||wrong.example^$script",
            "||.empty.example^", "||bad-.example^", "||127.0.0.1^", "||com^"))
        self.assertEqual(RULES.domains_from(text), {"analytics.example", "tracker.example"})

    def test_output_is_sorted_deduplicated_and_records_exact_sources(self):
        sources = {name: b"||z.example^\n||a.example^$third-party\n" for name in RULES.SOURCE_FILES}
        result = RULES.build_rules("a" * 40, sources)
        expected = sorted({"a.example", "z.example", *RULES.SUPPLEMENTAL_DOMAINS})
        self.assertEqual(result["domains"], expected)
        self.assertEqual(result["license"], "CC-BY-SA-3.0")
        digest = hashlib.sha256(("\n".join(expected) + "\n").encode()).hexdigest()
        self.assertEqual(result["revision"], "domain-rules-v1-" + digest)
        self.assertEqual(result["upstreamRevision"], "a" * 40)
        self.assertEqual(result["sources"], [{"path": name,
                         "sha256": hashlib.sha256(sources[name]).hexdigest()}
                        for name in RULES.SOURCE_FILES])

    def test_mutable_refs_and_incomplete_inventory_are_rejected(self):
        sources = {name: b"||tracker.example^\n" for name in RULES.SOURCE_FILES}
        for revision in ("master", "a" * 39, "A" * 40, "a" * 41):
            with self.subTest(revision=revision), self.assertRaises(ValueError):
                RULES.build_rules(revision, sources)
        sources.pop(next(iter(sources)))
        with self.assertRaises(ValueError):
            RULES.build_rules("a" * 40, sources)

    def test_empty_and_oversized_sources_fail(self):
        sources = {name: b"! no complete domain rules\n" for name in RULES.SOURCE_FILES}
        with self.assertRaises(ValueError):
            RULES.build_rules("a" * 40, sources)
        sources[next(iter(sources))] = b"x" * (RULES.MAX_SOURCE_BYTES + 1)
        with self.assertRaises(ValueError):
            RULES.build_rules("a" * 40, sources)

    def test_changed_content_changes_the_runtime_revision(self):
        sources = {name: b"||tracker.example^\n" for name in RULES.SOURCE_FILES}
        before = RULES.build_rules("a" * 40, sources)
        sources[next(iter(sources))] += b"||new.example^\n"
        after = RULES.build_rules("a" * 40, sources)
        self.assertNotEqual(before["revision"], after["revision"])

    def test_bundled_data_matches_its_revision_and_keeps_attribution(self):
        bundled = json.loads((ROOT / "Resources/Privacy/tracker-domains.json").read_text())
        domains = bundled["domains"]
        self.assertEqual(domains, sorted(set(domains)))
        self.assertGreater(len(domains), 1000)
        self.assertLessEqual(len(domains), 100000)
        self.assertTrue(set(RULES.SUPPLEMENTAL_DOMAINS).issubset(domains))
        self.assertFalse(any(domain.endswith((".localhost", ".test")) for domain in domains))
        digest = hashlib.sha256(("\n".join(domains) + "\n").encode()).hexdigest()
        self.assertEqual(bundled["revision"], "domain-rules-v1-" + digest)
        self.assertEqual(bundled["license"], "CC-BY-SA-3.0")
        self.assertEqual(bundled["attribution"], "The EasyList authors (https://easylist.to/)")
        self.assertEqual({source["path"] for source in bundled["sources"]}, set(RULES.SOURCE_FILES))
        self.assertTrue(all(len(source["sha256"]) == 64 for source in bundled["sources"]))


if __name__ == "__main__":
    unittest.main()
