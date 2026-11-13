# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep the display-capture picker hook pinned to the Chromium source build."""

import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
LAYER = ROOT / "ThirdParty/ChromiumEngine/layer"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0110-shaar-display-media-picker-delegate.patch"


def layer_digest(files):
    digest = hashlib.sha256()
    for name, file_digest in sorted(files.items()):
        digest.update(name.encode("utf-8") + b"\0" + file_digest.encode("ascii") + b"\n")
    return digest.hexdigest()


class DesktopCapturePickerPatchTests(unittest.TestCase):
    def test_picker_factory_routes_display_capture_requests(self):
        source = PATCH.read_text()
        self.assertIn("desktop_capture::IsActive()", source)
        self.assertIn("DISPLAY_VIDEO_CAPTURE", source)
        self.assertIn("DISPLAY_VIDEO_CAPTURE_SET", source)
        self.assertIn("desktop_capture::CreatePicker(*request)", source)
        self.assertIn("#if BUILDFLAG(IS_MAC)", source)

    def test_delegate_and_layer_sources_are_pinned(self):
        manifest = json.loads(MANIFEST.read_text())
        patch_path = str(PATCH.relative_to(ROOT))
        entries = [entry for entry in manifest["patches"] if entry["file"] == patch_path]
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["sha256"], hashlib.sha256(PATCH.read_bytes()).hexdigest())

        layer = manifest["layer"]
        files = layer["files"]
        for relative in (
            "chrome/browser/shaar/media/shaar_desktop_capture.cc",
            "chrome/browser/shaar/media/shaar_desktop_capture.h",
        ):
            self.assertIn(relative, files)
            self.assertEqual(
                files[relative], hashlib.sha256((LAYER / relative).read_bytes()).hexdigest()
            )
        self.assertEqual(layer["sha256"], layer_digest(files))

    def test_capture_reply_is_bound_to_the_pending_picker(self):
        picker = (LAYER / "chrome/browser/shaar/media/shaar_desktop_capture.cc").read_text()
        media = (LAYER / "chrome/browser/shaar/media/shaar_media.cc").read_text()
        self.assertIn("FindSelectedRegularTab", picker)
        self.assertIn("pending.frame_id", picker)
        self.assertIn("pending.source_types.contains(type)", picker)
        self.assertIn("SHAAR_OP_MEDIA_CAPTURE_REPLY", media)
        self.assertIn("desktop_capture::Resolve", media)

    def test_tab_tokens_keep_registry_uuid_casing_and_native_ids_are_canonical(self):
        picker = (LAYER / "chrome/browser/shaar/media/shaar_desktop_capture.cc").read_text()
        self.assertIn("base::Uuid::ParseCaseInsensitive(*value)", picker)
        self.assertNotIn("*value = uuid.AsLowercaseString();", picker)
        self.assertIn("std::to_string(native_id) == digits", picker)

    def test_expired_picker_notifies_the_app_to_dismiss_its_sheet(self):
        picker = (LAYER / "chrome/browser/shaar/media/shaar_desktop_capture.cc").read_text()
        cancel = picker[picker.index("void Cancel("):picker.index("bool IsCurrent(")]
        self.assertIn("NotifyDismissal(found->second, prompt_id)", cancel)
        self.assertIn('payload.Set("kind", "desktopCaptureDismissed")', picker)
        self.assertIn('payload.Set("id", prompt_id)', picker)
        self.assertIn("pending.window_id.data()", picker)
        self.assertIn("pending.tab_id.data()", picker)


if __name__ == "__main__":
    unittest.main()
