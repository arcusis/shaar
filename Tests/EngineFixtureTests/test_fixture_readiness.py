# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import contextlib
import importlib.util
import io
import json
import math
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location(
    'engine_fixture', Path(__file__).resolve().parents[2] / 'scripts/engine_fixture.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class FixtureReadinessTests(unittest.TestCase):
    def test_slow_download_catches_up_after_coarse_scheduler_wakes(self):
        clock = [0.0]

        def coarse_sleep(seconds):
            clock[0] += math.ceil(seconds / 0.1) * 0.1

        handler = object.__new__(fixture.Fixture)
        handler.headers = {'Cookie': 'account=alpha', 'Range': 'bytes=16384-'}
        handler.wfile = io.BytesIO()
        handler.send_response = Mock()
        handler.send_header = Mock()
        handler.end_headers = Mock()
        with patch.object(fixture.time, 'monotonic', side_effect=lambda: clock[0]), \
                patch.object(fixture.time, 'sleep', side_effect=coarse_sleep):
            handler.download('slow.txt')
        self.assertGreater(clock[0], 5.0)
        self.assertLess(clock[0], 5.3)
        expected = b'account=alpha\narcusis-download-fixture\n' + b'x' * (4 * 1024 * 1024)
        self.assertEqual(handler.wfile.getvalue(), expected[16384:])
        handler.send_response.assert_called_once_with(206)
        handler.send_header.assert_any_call(
            'Content-Range', f'bytes 16384-{len(expected)-1}/{len(expected)}')

    def test_failed_initial_private_fixture_cannot_launch_unseeded_restart(self):
        with tempfile.TemporaryDirectory(prefix='arcusis-engine-probe-') as temporary:
            root = Path(temporary)
            (root / 'initial.json').write_text(json.dumps(dict(
                phase='initial', passed=False, localFixturesPassed=False,
                fixtureStage='private-window', error='owner not released')))
            server = Mock(server_port=43123)
            process = Mock(pid=4321)
            process.poll.return_value = 1
            output = io.StringIO()
            with contextlib.redirect_stdout(output), \
                    patch.object(fixture.tempfile, 'mkdtemp', return_value=temporary), \
                    patch.object(fixture.shutil, 'copytree'), \
                    patch.object(fixture.http.server, 'ThreadingHTTPServer', return_value=server), \
                    patch.object(fixture.threading.Thread, 'start'), \
                    patch.object(fixture.subprocess, 'Popen', return_value=process) as popen, \
                    patch.object(fixture, 'wait_for_probe', return_value=1), \
                    patch.object(fixture, 'stop_probe'), \
                    patch.object(fixture, 'process_group_exists', return_value=False), \
                    patch.object(fixture, 'require_verification_bundle_identity'), \
                    patch.object(fixture, 'verify_fixture_listener_closed', return_value=True), \
                    patch.object(fixture, 'validate_private_window_report',
                                 side_effect=RuntimeError('owner not released')), \
                    patch.object(fixture, 'record_private_window_summary',
                                 return_value=dict(passed=False, proofDirectory='owned-proof')):
                with self.assertRaisesRegex(RuntimeError, 'owner not released'):
                    fixture.main(['--private-window'])
            self.assertEqual(popen.call_count, 1)
            self.assertIn('SKIPPED restart: initial fixture failed', output.getvalue())
            server.shutdown.assert_called_once()
            server.server_close.assert_called_once()


if __name__ == '__main__':
    unittest.main()
