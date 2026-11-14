# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""The shipping harness guard fails on a planted control and passes on this tree."""

import importlib.util
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "check_shipping_harness", REPO / "scripts" / "check-shipping-harness.py")
GUARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD)


class ShippingHarnessGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="shipping-harness-guard-")
        self.root = Path(self.temp.name)
        verification = self.root / "Sources" / "ShaarVerification"
        verification.mkdir(parents=True)
        (verification / "PlantedHarnessProbe.swift").write_text(
            "enum PlantedHarnessProbe {}\n"
            "let flag = \"--browsing-qa\"\n"
        )
        self.binary = self.root / "ArcusisBrowser"
        self.binary.write_bytes(b"clean shipping executable")

    def tearDown(self):
        self.temp.cleanup()

    def plant(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def test_repository_sources_have_no_shipping_harness(self):
        self.assertEqual(GUARD.findings(REPO), [])

    def test_clean_tree_passes(self):
        self.plant("Sources/ArcusisBrowser/Browser.swift", "let title = \"Shaar\"\n")
        self.assertEqual(GUARD.findings(self.root, self.binary), [])

    def test_planted_probe_flag_fails(self):
        self.plant(
            "Sources/ArcusisBrowser/Planted.swift",
            "let launch = \"--planted-probe\"\n",
        )
        found = GUARD.findings(self.root, self.binary)
        self.assertTrue(any("--planted-probe" in item for item in found), found)

    def test_planted_smoke_flag_in_the_bridge_fails(self):
        self.plant(
            "Sources/ChromiumBridge/Planted.mm",
            "NSString *flag = @\"--bridge-smoke\";\n",
        )
        found = GUARD.findings(self.root)
        self.assertTrue(any("--bridge-smoke" in item for item in found), found)

    def test_planted_testing_true_fails(self):
        self.plant(
            "Sources/ArcusisBrowser/Planted.swift",
            "let code = runtime.run(withDataDirectory: root, testing: true)\n",
        )
        found = GUARD.findings(self.root)
        self.assertTrue(any("testing: true" in item for item in found), found)

    def test_planted_verification_symbol_fails(self):
        self.plant(
            "Sources/ChromiumBridge/Planted.mm",
            "return PlantedHarnessProbe();\n",
        )
        found = GUARD.findings(self.root)
        self.assertTrue(any("PlantedHarnessProbe" in item for item in found), found)

    def test_planted_binary_symbol_fails(self):
        self.binary.write_bytes(b"prefix PlantedHarnessProbe suffix")
        found = GUARD.findings(self.root, self.binary)
        self.assertTrue(any("PlantedHarnessProbe" in item for item in found), found)

    def test_product_launch_flag_is_allowed(self):
        self.plant(
            "Sources/ArcusisBrowser/Browser.swift",
            "if arguments.contains(\"--render-preview\") {}\n",
        )
        self.assertEqual(GUARD.findings(self.root, self.binary), [])

    def test_verification_only_qa_flag_fails_in_shipping_source(self):
        self.plant(
            "Sources/ArcusisBrowser/Browser.swift",
            "let flag = \"--browsing-qa\"\n",
        )
        found = GUARD.findings(self.root)
        self.assertTrue(any("--browsing-qa" in item for item in found), found)

    def test_verification_dispatch_flag_fails_in_the_binary(self):
        self.plant(
            "Sources/ShaarVerification/Route.swift",
            "if CommandLine.arguments.contains(\"--devtools-f12-route\") {}\n",
        )
        self.binary.write_bytes(b"prefix --devtools-f12-route suffix")
        found = GUARD.findings(self.root, self.binary)
        self.assertTrue(any("--devtools-f12-route" in item for item in found), found)

    def test_verification_only_fixture_id_fails_in_the_binary(self):
        self.plant(
            "Sources/ShaarVerification/Click.swift",
            "let elementID = \"parity-action\"\n",
        )
        self.binary.write_bytes(b"prefix parity-action suffix")
        found = GUARD.findings(self.root, self.binary)
        self.assertTrue(any("parity-action" in item for item in found), found)

    def test_fixture_id_quoted_in_shipping_source_fails(self):
        self.plant(
            "Sources/ShaarVerification/Click.swift",
            "let elementID = \"parity-action\"\n",
        )
        self.plant(
            "Sources/ArcusisBrowser/Browser.swift",
            "let elementID = \"parity-action\"\n",
        )
        found = GUARD.findings(self.root)
        self.assertTrue(any("parity-action" in item for item in found), found)

    def test_product_phrase_mentioned_by_shipping_stays_in_the_binary(self):
        self.plant(
            "Sources/ShaarVerification/Media.swift",
            "let mode = \"picture-in-picture\"\n",
        )
        self.plant(
            "Sources/ArcusisBrowser/Browser.swift",
            "// picture-in-picture stays in the product\n",
        )
        self.binary.write_bytes(b"prefix picture-in-picture suffix")
        self.assertEqual(GUARD.findings(self.root, self.binary), [])

    def test_shared_non_product_dispatch_flag_fails(self):
        self.plant(
            "Sources/ShaarVerification/Route.swift",
            "if CommandLine.arguments.contains(\"--secret-route\") {}\n",
        )
        self.plant(
            "Sources/ArcusisBrowser/Browser.swift",
            "if arguments.contains(\"--secret-route\") {}\n",
        )
        found = GUARD.findings(self.root)
        self.assertTrue(any("--secret-route" in item for item in found), found)

    def test_underscore_and_mangled_symbols_fail_in_the_binary(self):
        name = b"PlantedHarnessProbe"
        self.binary.write_bytes(b"prefix _" + name + b" suffix")
        found = GUARD.findings(self.root, self.binary)
        self.assertTrue(any("PlantedHarnessProbe" in item for item in found), found)

        self.binary.write_bytes(b"prefix " + str(len(name)).encode() + name + b" suffix")
        found = GUARD.findings(self.root, self.binary)
        self.assertTrue(any("PlantedHarnessProbe" in item for item in found), found)

        self.binary.write_bytes(b"prefix 1" + str(len(name)).encode() + name + b" suffix")
        found = GUARD.findings(self.root, self.binary)
        self.assertFalse(any("PlantedHarnessProbe" in item for item in found), found)

    def test_indented_type_in_another_source_root_fails(self):
        self.plant(
            "Sources/ShaarVerification/Nested.swift",
            "enum Outer {\n    enum NestedHarnessProbe {}\n}\n",
        )
        self.plant(
            "Sources/BrowserCore/Use.swift",
            "let value = NestedHarnessProbe()\n",
        )
        found = GUARD.findings(self.root)
        self.assertTrue(any("NestedHarnessProbe" in item for item in found), found)

    def test_lowercase_probe_method_in_the_engine_abi_fails(self):
        self.plant(
            "Sources/ChromiumBridgeVerification/Planted.mm",
            "- (void)probePlantedFixture {\n}\n",
        )
        self.plant(
            "Sources/ShaarEngineABI/Use.h",
            "void probePlantedFixture(void);\n",
        )
        found = GUARD.findings(self.root)
        self.assertTrue(any("probePlantedFixture" in item for item in found), found)

    def test_lowercase_swift_probe_function_fails(self):
        self.plant(
            "Sources/ShaarVerification/Planted.swift",
            "func probePlantedRoute() {}\n",
        )
        self.plant(
            "Sources/Shaar/Call.swift",
            "probePlantedRoute()\n",
        )
        found = GUARD.findings(self.root)
        self.assertTrue(any("probePlantedRoute" in item for item in found), found)

    def test_engine_testing_read_outside_start_fails(self):
        self.plant(
            "Sources/ChromiumBridge/Planted.mm",
            "const char *testing = getenv(\"SHAAR_ENGINE_TESTING\");\n",
        )
        found = GUARD.findings(self.root)
        self.assertTrue(any("SHAAR_ENGINE_TESTING" in item for item in found), found)

    def test_engine_testing_read_is_allowed_in_verification_compile_guard(self):
        self.plant(
            "Sources/ChromiumBridge/Planted.mm",
            "#if defined(SHAAR_VERIFICATION)\n"
            'const char *testing = getenv("SHAAR_ENGINE_TESTING");\n'
            "#endif\n",
        )
        self.assertEqual(GUARD.findings(self.root), [])

    def test_engine_testing_start_write_is_allowed(self):
        self.plant(
            "Sources/ChromiumBridge/ChromiumShaarBackend.mm",
            "- (int)runWithDataDirectory:(NSURL *)directory testing:(BOOL)testing {\n"
            "#if defined(SHAAR_VERIFICATION)\n"
            "  // The pinned engine reads SHAAR_ENGINE_TESTING.\n"
            "  setenv(\"SHAAR_ENGINE_TESTING\", engineTesting, 1);\n"
            "  unsetenv(\"SHAAR_ENGINE_TESTING\");\n"
            "#endif\n"
            "}\n",
        )
        self.assertEqual(GUARD.findings(self.root), [])

    def test_engine_testing_read_in_the_start_file_fails(self):
        self.plant(
            "Sources/ChromiumBridge/ChromiumShaarBackend.mm",
            "- (int)runWithDataDirectory:(NSURL *)directory testing:(BOOL)testing {\n"
            "  const char *testing = getenv(\"SHAAR_ENGINE_TESTING\");\n"
            "}\n",
        )
        found = GUARD.findings(self.root)
        self.assertTrue(any("SHAAR_ENGINE_TESTING" in item for item in found), found)

    def test_engine_testing_shipping_else_branch_fails(self):
        self.plant(
            "Sources/ChromiumBridge/ChromiumShaarBackend.mm",
            "#if defined(SHAAR_VERIFICATION)\n"
            '  setenv("SHAAR_ENGINE_TESTING", "1", 1);\n'
            "#else\n"
            '  getenv("SHAAR_ENGINE_TESTING");\n'
            "#endif\n",
        )
        found = GUARD.findings(self.root)
        self.assertTrue(any("SHAAR_ENGINE_TESTING" in item for item in found), found)

    def test_engine_testing_after_url_string_is_not_hidden_as_comment(self):
        self.plant(
            "Sources/ChromiumBridge/Planted.mm",
            'NSString *url = @"https://example.test"; const char *value = getenv("SHAAR_ENGINE_TESTING");\n',
        )
        found = GUARD.findings(self.root)
        self.assertTrue(any("SHAAR_ENGINE_TESTING" in item for item in found), found)

    def test_engine_testing_in_lookalike_start_method_is_not_allowed(self):
        self.plant(
            "Sources/ChromiumBridge/Backend.mm",
            "- (int)runWithDataDirectory:(NSURL *)directory testing:(BOOL)testing {\n"
            '  setenv("SHAAR_ENGINE_TESTING", "1", 1);\n'
            "}\n",
        )
        found = GUARD.findings(self.root)
        self.assertTrue(any("SHAAR_ENGINE_TESTING" in item for item in found), found)

    def test_engine_testing_read_in_verification_else_branch_fails(self):
        self.plant(
            "Sources/ChromiumBridge/Planted.mm",
            "#if defined(SHAAR_VERIFICATION)\n"
            '  const char *verification = getenv("SHAAR_ENGINE_TESTING");\n'
            "#else\n"
            '  const char *shipping = getenv("SHAAR_ENGINE_TESTING");\n'
            "#endif\n",
        )
        found = GUARD.findings(self.root)
        self.assertEqual(len(found), 1, found)
        self.assertIn(":4: SHAAR_ENGINE_TESTING", found[0])

    def test_engine_testing_read_in_verification_elif_branch_is_allowed(self):
        self.plant(
            "Sources/ChromiumBridge/Planted.mm",
            "#if defined(OTHER_FEATURE)\n"
            '  const char *shipping = getenv("SHAAR_ENGINE_TESTING");\n'
            "#elif defined(SHAAR_VERIFICATION)\n"
            '  const char *verification = getenv("SHAAR_ENGINE_TESTING");\n'
            "#else\n"
            '  const char *also_shipping = getenv("SHAAR_ENGINE_TESTING");\n'
            "#endif\n",
        )
        found = GUARD.findings(self.root)
        self.assertEqual(len(found), 2, found)
        self.assertTrue(all(":2:" in item or ":6:" in item for item in found), found)

    def test_nested_conditionals_keep_the_outer_verification_branch_scope(self):
        self.plant(
            "Sources/ChromiumBridge/Planted.mm",
            "#if defined(SHAAR_VERIFICATION)\n"
            "  #if defined(OPTIONAL_FIXTURE)\n"
            '    const char *nested = getenv("SHAAR_ENGINE_TESTING");\n'
            "  #endif\n"
            '  const char *verification = getenv("SHAAR_ENGINE_TESTING");\n'
            "#else\n"
            '  const char *shipping = getenv("SHAAR_ENGINE_TESTING");\n'
            "#endif\n",
        )
        found = GUARD.findings(self.root)
        self.assertEqual(len(found), 1, found)
        self.assertIn(":7: SHAAR_ENGINE_TESTING", found[0])

    def test_ifdef_verification_branch_is_allowed_but_else_is_not(self):
        self.plant(
            "Sources/ChromiumBridge/Planted.mm",
            "#ifdef SHAAR_VERIFICATION\n"
            '  const char *verification = getenv("SHAAR_ENGINE_TESTING");\n'
            "#else\n"
            '  const char *shipping = getenv("SHAAR_ENGINE_TESTING");\n'
            "#endif\n",
        )
        found = GUARD.findings(self.root)
        self.assertEqual(len(found), 1, found)
        self.assertIn(":4: SHAAR_ENGINE_TESTING", found[0])

    def test_probe_operation_reference_fails_in_shipping_source_and_binary(self):
        operation = "SHAAR_OP_PROBE_PLANTED_FIXTURE"
        self.plant(
            "Sources/ChromiumBridge/Planted.mm",
            f"shaar_operation operation = {operation};\n",
        )
        found = GUARD.findings(self.root)
        self.assertTrue(any(operation in item for item in found), found)

        self.plant("Sources/ChromiumBridge/Planted.mm", "// clean\n")
        self.binary.write_bytes(b"prefix " + operation.encode() + b" suffix")
        found = GUARD.findings(self.root, self.binary)
        self.assertTrue(any(operation in item for item in found), found)

    def test_generic_verification_symbol_collision_is_ignored_in_binary(self):
        self.plant(
            "Sources/ShaarVerification/Framework.swift",
            "enum FrameworkDevTools {}\n",
        )
        self.binary.write_bytes(b"prefix FrameworkDevTools suffix")
        self.assertEqual(GUARD.findings(self.root, self.binary), [])

    def test_acronym_prefixed_probe_symbol_fails_in_binary(self):
        self.plant(
            "Sources/ShaarVerification/Probe.swift",
            "enum ARCProbePlantedHarness {}\n",
        )
        self.binary.write_bytes(b"prefix _ARCProbePlantedHarness suffix")
        found = GUARD.findings(self.root, self.binary)
        self.assertTrue(any("ARCProbePlantedHarness" in item for item in found), found)

    def test_unmatched_quote_at_newline_does_not_hide_following_comment(self):
        source = self.plant(
            "Sources/ChromiumBridge/Planted.mm",
            "NSString *broken = 'stray\n"
            "// SHAAR_ENGINE_TESTING appears only in this comment\n",
        )
        self.assertEqual(
            GUARD.engine_testing_findings(source, source.read_text()), []
        )

    def test_nested_swift_block_comments_do_not_report_harness_tokens(self):
        source = self.plant(
            "Sources/ArcusisBrowser/Comment.swift",
            "/* outer /* SHAAR_ENGINE_TESTING */ still a comment */\n",
        )
        self.assertEqual(GUARD.engine_testing_findings(source, source.read_text()), [])

    def test_engine_testing_string_in_the_binary_fails(self):
        self.binary.write_bytes(b"prefix SHAAR_ENGINE_TESTING suffix")
        found = GUARD.findings(self.root, self.binary)
        self.assertTrue(any("SHAAR_ENGINE_TESTING" in item for item in found), found)

    def test_forged_chooser_channel_fails_in_shipping_source(self):
        self.plant(
            "Sources/ArcusisBrowser/Planted.swift",
            "let title = \"shaar-chooser:usb\"\n",
        )
        found = GUARD.findings(self.root)
        self.assertTrue(any("shaar-chooser:" in item for item in found), found)

    def test_forged_chooser_channel_fails_in_the_binary(self):
        self.binary.write_bytes(b"prefix shaar-chooser: suffix")
        found = GUARD.findings(self.root, self.binary)
        self.assertTrue(any("shaar-chooser:" in item for item in found), found)

    def test_shared_product_dispatch_flag_is_allowed(self):
        self.plant(
            "Sources/ShaarVerification/Preview.swift",
            "if CommandLine.arguments.contains(\"--render-preview\") {}\n",
        )
        self.plant(
            "Sources/ArcusisBrowser/Browser.swift",
            "if arguments.contains(\"--render-preview\") {}\n",
        )
        self.binary.write_bytes(b"prefix --render-preview suffix")
        self.assertEqual(GUARD.findings(self.root, self.binary), [])


if __name__ == "__main__":
    unittest.main()
