from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class InspectorNotesProgressLabelBindingTests(unittest.TestCase):
    def test_busy_progress_view_has_a_voiceover_label(self):
        source = (ROOT / "Sources/ArcusisBrowser/InspectorNotesView.swift").read_text(
            encoding="utf-8"
        )
        progress = source.split("if model.busy", 1)[1].split(
            "if let value = model.status", 1
        )[0]

        self.assertIn("ProgressView()", progress)
        self.assertIn(
            '.accessibilityLabel(InspectorL10n.string("Working…"))',
            progress,
        )


if __name__ == "__main__":
    unittest.main()
