# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
LAYER = ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar"
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0066-shaar-save-prompts.patch"
BRIDGE = ROOT / "Sources/ChromiumBridgeVerification/ChromiumBridgeVerification.mm"
PROBE = ROOT / "Sources/ShaarVerification/ShaarSavePromptProbe.swift"
FIXTURE = ROOT / "scripts/test-shaar-save-prompt.py"


class SavePromptTrustedTextTests(unittest.TestCase):
    def test_text_operation_is_narrow_and_uses_chromium_ime_input(self):
        header = (LAYER / "public/shaar_engine.h").read_text()
        source = (LAYER / "devtools/shaar_devtools.cc").read_text()
        tests = (LAYER / "devtools/shaar_devtools_unittest.cc").read_text()
        self.assertIn("SHAAR_OP_PROBE_TRUSTED_TEXT = 1099", header)
        self.assertIn("ParseProbeTextArguments", source)
        self.assertIn("widget->GetWidgetInputHandler()->ImeCommitText", source)
        self.assertIn("ProbeWindowAllowed", source)
        for field in (
            "username", "password", "card-name", "card-number", "card-exp-month",
            "card-exp-year", "address-name", "address-street", "address-city",
            "address-region", "address-postal", "address-country", "address-email",
        ):
            with self.subTest(field=field):
                self.assertIn(f'"{field}"', source)
                self.assertIn(f'"{field}"', tests)
        self.assertIn("ParseProbeTextArguments(Bytes(invalid)", tests)

    def test_hook_and_offer_diagnostics_are_redacted_and_testing_only(self):
        prompt_source = (LAYER / "save_prompts/shaar_save_prompts.cc").read_text()
        patch = PATCH.read_text()
        self.assertIn('std::strcmp(testing, "1") == 0', prompt_source)
        self.assertIn("offer:context-denied", prompt_source)
        self.assertIn("offer:no-selected-regular-tab", prompt_source)
        self.assertIn('"offer:event-emitted"', prompt_source)
        self.assertIn('"offer:event-rejected"', prompt_source)
        harness = FIXTURE.read_text()
        self.assertIn('DIAGNOSTIC_PREFIX = "SHAAR_SAVE_PROMPT_DIAGNOSTIC "', harness)
        self.assertIn('"diagnosticStages": diagnostics', harness)
        self.assertIn('if stage in DIAGNOSTIC_STAGES:', harness)
        for hook in ("password", "card", "address"):
            with self.subTest(hook=hook):
                self.assertIn(f'"hook:{hook}"', patch)
        self.assertNotIn("parity-secret", prompt_source + patch)
        self.assertNotIn("4111111111111111", prompt_source + patch)

    def test_probe_enters_values_and_fixture_starts_empty(self):
        bridge = BRIDGE.read_text()
        probe = PROBE.read_text()
        fixture = FIXTURE.read_text()
        self.assertIn('"--probe-data-dir", str(root)', fixture)
        self.assertIn("submitTrustedProbeTextInTabID", bridge)
        self.assertIn("shaarDevToolsSubmit:1099", bridge)
        self.assertIn("valuesEntered", probe)
        self.assertIn("valueMatches: field?.value === value", probe)
        self.assertNotIn('value="parity-user"', fixture)
        self.assertNotIn('value="4111111111111111"', fixture)
        self.assertNotIn('value="Parity Probe"', fixture)

    def test_text_uses_the_same_non_key_transparent_surface_guard_as_clicks(self):
        bridge = BRIDGE.read_text()
        helper = bridge[bridge.index("BOOL ProbeTrustedInputSurfaceAllowed"):]
        text_handler = bridge[bridge.index("submitTrustedProbeTextInTabID"):]
        self.assertIn("!pageWindow.isKeyWindow", helper)
        self.assertIn("pageWindow.alphaValue == 0", helper)
        self.assertIn("pageWindow.ignoresMouseEvents", helper)
        self.assertIn("if (!ProbeTrustedInputSurfaceAllowed(view))", text_handler)
        self.assertNotIn("view.window.isVisible", text_handler)
        self.assertNotIn("for (NSWindow *window in NSApp.windows)", text_handler)

    def test_native_preflight_diagnostics_are_testing_only_and_redacted(self):
        bridge = BRIDGE.read_text()
        self.assertIn('NSLog(@"Trusted probe text: trusted input failed at %s", stage)', bridge)
        self.assertIn('NSLog(@"Trusted probe text: trace: %s", stage)', bridge)
        self.assertIn('std::strcmp(testing, "1") == 0 && ProbeCaptureAllowed()', bridge)
        self.assertIn('LogTrustedInputTrace("bridge handler entered")', bridge)
        self.assertIn('LogTrustedInputFailure("engine request rejected")', bridge)
        self.assertIn('LogTrustedInputFailure("engine reply not submitted")', bridge)
        self.assertIn('LogTrustedInputFailure("invalid fixture text request")', bridge)
        self.assertIn('LogTrustedInputFailure("render surface unavailable")', bridge)
        self.assertIn('LogTrustedInputFailure("tab ownership unavailable")', bridge)
        self.assertNotIn('LogTrustedInputFailure([elementID', bridge)
        self.assertNotIn('LogTrustedInputFailure([text', bridge)

    def test_frame_capture_retries_transient_unpresented_frames(self):
        probe = PROBE.read_text()
        capture = probe[probe.index("private static func captureFrame"):]
        self.assertIn("for attempt in 0..<4", capture)
        self.assertIn("Task.sleep(for: .milliseconds(75))", capture)

    def test_trusted_text_operation_is_registered_and_covered_by_engine_test(self):
        adapter = (LAYER / "devtools/shaar_devtools_lifecycle_adapter.cc").read_text()
        engine_tests = (LAYER / "devtools/shaar_devtools_unittest.cc").read_text()
        self.assertIn(
            "registry->Register(SHAAR_OP_PROBE_TRUSTED_TEXT,\n"
            "                     SHAAR_OP_PROBE_TRUSTED_TEXT,",
            adapter,
        )
        self.assertIn("registry.Find(SHAAR_OP_PROBE_TRUSTED_TEXT)", engine_tests)

    def test_trusted_input_failures_report_only_the_stage(self):
        source = (LAYER / "devtools/shaar_devtools.cc").read_text()
        for stage in (
            "capture lease wait timed out",
            "target unavailable while waiting for capture lease",
            "target unavailable at start",
            "target unavailable before snapshot", "forced snapshot was empty",
            "tab disappeared after snapshot", "target unavailable after snapshot",
            "main frame unavailable after snapshot",
            "element point unavailable or outside view",
            "target unavailable at element point",
            "target unavailable before dispatch",
            "focused frame widget unavailable before text commit", "capture timed out",
        ):
            with self.subTest(stage=stage):
                self.assertIn(f'Fail("{stage}")', source)
        self.assertIn('std::string("trusted input failed at ") + stage', source)
        self.assertNotIn('std::string("trusted input failed at ") + text_', source)

    def test_trusted_text_focuses_widget_and_waits_for_renderer_commit_ack(self):
        source = (LAYER / "devtools/shaar_devtools.cc").read_text()
        commit = source[source.index("  void CommitText()"):
                        source.index("  void CompleteSuccess()", source.index("  void CommitText()"))]
        self.assertIn("focused_widget->Focus();", commit)
        self.assertIn("focused_widget->GetWidgetInputHandler()->ImeCommitText(", commit)
        self.assertIn("ProbeTrustedInput::OnTextCommitted", commit)
        self.assertIn("void OnTextCommitted()", commit)
        self.assertNotIn("CompleteSuccess();", commit.split("void OnTextCommitted()", 1)[0])
        self.assertIn("CompleteSuccess();", commit.split("void OnTextCommitted()", 1)[1])

    def test_save_prompt_probe_reports_field_state_without_values(self):
        probe = PROBE.read_text()
        self.assertIn('"trustedTextDiagnostics": trustedTextDiagnostics', probe)
        self.assertIn("valueMatches: field?.value === value", probe)
        self.assertIn("valueLength: field instanceof HTMLInputElement ? field.value.length : null", probe)
        self.assertIn("activeElementIsInput: active instanceof HTMLInputElement", probe)
        self.assertNotIn("value:field.value", probe)
    def test_text_commit_targets_the_focused_frame_widget(self):
        source = (LAYER / "devtools/shaar_devtools.cc").read_text()
        commit = source[source.index("  void CommitText()"):
                        source.index("  void CompleteSuccess()", source.index("  void CommitText()"))]
        self.assertIn("contents->GetFocusedFrame()", commit)
        self.assertIn("focused_frame->GetRenderWidgetHost()", commit)
        self.assertIn('Fail("focused frame widget unavailable before text commit")', commit)
        self.assertIn("focused_widget->input_router()->MakeActive()", commit)
        self.assertIn("focused_widget->GetWidgetInputHandler()->SetFocus(", commit)
        self.assertIn("blink::mojom::FocusState::kFocused", commit)
        self.assertIn("focused_widget->GetWidgetInputHandler()->ImeCommitText(", commit)
        self.assertNotIn("auto* widget = Activate();", commit)


if __name__ == "__main__":
    unittest.main()
