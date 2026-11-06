# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('shaar_quit_probe', ROOT / 'scripts/probe-shaar-quit.py')
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class ShaarQuitProbeTests(unittest.TestCase):
    def report(self):
        names = {
            'openTab', 'navigate', 'backForward', 'devTools', 'newWindow',
            'privateWindow', 'profilesSwitch', 'extensions', 'downloads',
            'privateEngineProfileIsOffTheRecord', 'privateEngineGlobalCookiesBlocked',
            'privateEngineHTTPSOnlyEnabled', 'privateEngineReferrersDisabled',
            'privateEngineWebRTCPublicIPOnly', 'privateEngineExtensionsDisabled',
            'privateEngineTrackerRulesLoaded',
        }
        return dict(passed=True, allWindowsHidden=True, visibleWindowEvidence=[],
                    results={name: dict(status='pass') for name in names})

    def validate(self, report):
        def run(args, **kwargs):
            output = Path(args[args.index('--probe-output') + 1])
            output.write_text(json.dumps(report))
            return subprocess.CompletedProcess(args, 0, stderr=b'')
        with tempfile.TemporaryDirectory() as folder, patch.object(PROBE.subprocess, 'run', run):
            return PROBE.run_probe(Path('/unused-test-app'), Path(folder), 'private-live', 1, 1234, 30)

    def test_accepts_complete_private_live_report(self):
        self.assertTrue(self.validate(self.report()))

    def test_every_policy_is_required_and_must_pass(self):
        for name in self.report()['results']:
            if not name.startswith('privateEngine'):
                continue
            with self.subTest(name=name):
                missing = self.report()
                del missing['results'][name]
                self.assertFalse(self.validate(missing))
                failed = self.report()
                failed['results'][name]['status'] = 'fail'
                self.assertFalse(self.validate(failed))

    def test_unknown_checks_and_visible_windows_still_fail(self):
        extra = self.report()
        extra['results']['unexpected'] = dict(status='pass')
        self.assertFalse(self.validate(extra))
        visible = self.report()
        visible['visibleWindowEvidence'] = ['visible window']
        self.assertFalse(self.validate(visible))


if __name__ == '__main__':
    unittest.main()
