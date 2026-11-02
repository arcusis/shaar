# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import plistlib
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import sidebar_dnd_fixture as fixture


class SidebarTypeFixtureTests(unittest.TestCase):
    def test_failed_test_body_unregisters_only_owned_bundle_and_never_launches_it(self):
        commands = []
        owned_bundle = None

        def register(command, **options):
            commands.append(command)
            self.assertEqual(command[0], str(fixture.LSREGISTER))
            self.assertTrue(options["check"])
            self.assertEqual(options["timeout"], 30)

        with patch.object(fixture.subprocess, "run", side_effect=register):
            with self.assertRaisesRegex(RuntimeError, "authored test failure"):
                with fixture.registered_sidebar_type() as bundle:
                    owned_bundle = bundle
                    metadata = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
                    self.assertTrue(metadata["LSBackgroundOnly"])
                    declaration = metadata["UTExportedTypeDeclarations"][0]
                    self.assertEqual(declaration["UTTypeIdentifier"], fixture.SIDEBAR_TYPE)
                    self.assertEqual(declaration["UTTypeConformsTo"], ["public.data"])
                    raise RuntimeError("authored test failure")
        self.assertEqual(commands, [
            [str(fixture.LSREGISTER), "-f", str(owned_bundle)],
            [str(fixture.LSREGISTER), "-u", str(owned_bundle)],
        ])
        self.assertFalse(owned_bundle.exists())

    def test_failed_registration_never_runs_tests_and_still_cleans_owned_metadata(self):
        commands = []

        def register(command, **options):
            commands.append(command)
            if command[1] == "-f":
                raise subprocess.CalledProcessError(1, command)

        with patch.object(fixture.subprocess, "run", side_effect=register):
            with self.assertRaises(subprocess.CalledProcessError):
                with fixture.registered_sidebar_type():
                    self.fail("Tests ran without their pasteboard type")
        self.assertEqual([command[1] for command in commands], ["-f", "-u"])
        self.assertEqual(commands[0][2], commands[1][2])
        self.assertFalse(Path(commands[0][2]).exists())
