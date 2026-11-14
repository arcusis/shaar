from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ProfilePermissionsProgressLabelBindingTests(unittest.TestCase):
    def test_busy_progress_view_uses_the_accessibility_status_label(self):
        source = (ROOT / "Sources/ArcusisBrowser/ProfilePrivacySections.swift").read_text(
            encoding="utf-8"
        )
        progress = source.split("if let busyMessage = model.busyMessage", 1)[1].split(
            "Spacer()", 1
        )[0]

        self.assertIn("ProgressView(busyMessage)", progress)
        self.assertIn(
            ".accessibilityLabel(ProfilePrivacyAccessibility.progressLabel(for: busyMessage))",
            progress,
        )


if __name__ == "__main__":
    unittest.main()
