from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class InspectorAuditHeadingBindingTests(unittest.TestCase):
    def test_impact_group_text_uses_heading_trait(self):
        source = (ROOT / "Sources/ArcusisBrowser/InspectorAuditView.swift").read_text(
            encoding="utf-8"
        )
        group = source.split("private struct InspectorAuditImpactGroup", 1)[1].split(
            "ForEach(findings)", 1
        )[0]

        self.assertIn(
            'Text(InspectorDetailsL10n.string(impact.capitalized))',
            group,
        )
        self.assertIn(
            ".accessibilityAddTraits(InspectorAuditView.impactGroupHeadingTraits)",
            group,
        )


if __name__ == "__main__":
    unittest.main()
