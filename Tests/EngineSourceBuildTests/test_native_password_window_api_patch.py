import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / 'ThirdParty/ArdiaCore/patches/native-password-window-api.patch'
BASE = ROOT / 'ThirdParty/ArdiaCore/patches/native-password-provider.patch'
CANDIDATE = PATCH.with_suffix('.candidate.json')
DEFAULT_SOURCE = ROOT / 'build/EngineSource/chromium_git/chromium/src'
CHROMIUM = '5869fe313571d75152b77813cf0a4ee26a4e6df0'
ARDIA = '91e17a5655519d2dc385ec8452432469232ff9af'
BASE_HASH = '45062b8a0877217160482cd1c8374cd8d714484213d762397b5728816ba7576c'
ARDIA_HASHES = {
    'ardia/core/BUILD.gn': '4308ed17c4ea07ecdb4cbded04d741420e636ac643bb4956b75f9d6b56b795e0',
    'ardia/core/ac_browser.h': 'b17c02666132bb5896c4c7d7481404d11fa5163ece448b456405aee4b247626b',
    'ardia/core/ac_browser.mm': 'e16265e4b3143ab3dde69638a12d68a49cde2dfb5521486c946df39418b580f4',
    'ardia/core/ardiacore_api.mm': '252badb5e6370dad44e9d1d61c715e5383d4cf4f073e4f31c5bad6b9909a2afa',
    'ardia/core/public/ArdiaCore.h': '0fd7373014b0180a95e17cf4f46cf0aa4dc711e14bc022dde62cc765f335ef1c',
}
PATHS = [
    'ardia/core/BUILD.gn', 'ardia/core/ac_browser.h', 'ardia/core/ac_browser.mm',
    'ardia/core/ac_native_password_broker.h', 'ardia/core/ac_native_password_broker.mm',
    'ardia/core/ac_native_password_completion_gate.h',
    'ardia/core/ac_native_password_window_api_browsertest.mm',
    'ardia/core/ardiacore_api.mm', 'ardia/core/public/ArdiaCore.h',
]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def paths(patch):
    return re.findall(r'^diff --git a/(\S+) b/\1$', patch.decode(), re.M)


def validate(meta, patch, base):
    keys = {'schema_version', 'chromium_commit', 'chromium_version', 'ardia_commit',
            'base_patch_sha256', 'source_ardia_sha256', 'patch_sha256', 'patch_bytes',
            'changed_paths', 'accepted', 'compiled', 'integration_ready',
            'native_async_cancellation_supported', 'supported', 'unsupported', 'status'}
    if set(meta) != keys or type(meta['schema_version']) is not int or meta['schema_version'] != 1:
        raise ValueError('metadata schema')
    pin = json.loads((ROOT / 'ThirdParty/ArdiaCore/pin.json').read_text())
    if (meta['chromium_commit'] != CHROMIUM or meta['ardia_commit'] != ARDIA or
            meta['chromium_version'] != '155.0.8059.84' or
            pin['sourceCommit'] != ARDIA or pin['chromiumVersion'] != meta['chromium_version']):
        raise ValueError('source pin')
    if meta['base_patch_sha256'] != BASE_HASH or digest(base) != BASE_HASH:
        raise ValueError('base patch')
    if meta['source_ardia_sha256'] != ARDIA_HASHES:
        raise ValueError('ardia content pin')
    if (type(meta['patch_bytes']) is not int or meta['patch_bytes'] != len(patch) or
            meta['patch_sha256'] != digest(patch)):
        raise ValueError('patch hash or size')
    if paths(patch) != PATHS or meta['changed_paths'] != PATHS:
        raise ValueError('patch scope')
    if any(meta[key] is not False for key in ('accepted', 'compiled', 'integration_ready',
                                               'native_async_cancellation_supported')):
        raise ValueError('acceptance')
    if (meta['status'] != 'native_window_api_candidate_uncompiled' or
            not isinstance(meta['supported'], list) or not meta['supported'] or
            not isinstance(meta['unsupported'], list) or
            'cancellation after consume cannot undo renderer work already delivered; renderer document, form and focus checks govern fill' not in meta['unsupported']):
        raise ValueError('scope disclosure')
    return patch.decode()


class NativePasswordWindowPatchTests(unittest.TestCase):
    def setUp(self):
        self.meta = json.loads(CANDIDATE.read_text())
        self.patch = PATCH.read_bytes()
        self.base = BASE.read_bytes()

    def test_pins_scope_and_connection(self):
        text = validate(self.meta, self.patch, self.base)
        for fragment in ('@interface ArdiaCorePasswordFillRequest', 'requestPasswordFillForTab:',
                         'fillPasswordRequest:', 'cancelPasswordRequest:',
                         'NativePasswordBroker::GetOrCreate', 'broker->Request(',
                         'request->_broker->Consume(', 'request->_broker->Cancel(',
                         'GetActiveWebContents() != contents', 'IsOffTheRecord()',
                         'WebContentsUserData<NativePasswordBroker>',
                         'GetWeakPtr()', 'selection_generation()',
                         'password_callbacks->Notify()', 'OnRequestTimeout',
                         'PasswordCompletionGate', 'gate->Fail()', 'gate->Finish()',
                         'HostDestructionFencesPendingGate', 'PendingDeadlineAndLateReplyCompleteOnce',
                         'SuccessAndReplay', 'WrongOwnerTabAndCancel', 'PrivateProfileRejected',
                         'ac_native_password_window_api_browsertest.mm', 'testonly = true'):
            self.assertIn(fragment, text, fragment)

    def test_pinned_source_application(self):
        validate(self.meta, self.patch, self.base)
        source = Path(os.environ.get('NATIVE_PASSWORD_WINDOW_CHROMIUM_SOURCE', DEFAULT_SOURCE))
        if not source.is_dir():
            self.skipTest('pinned source unavailable')
        revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip()
        self.assertEqual(CHROMIUM, revision)
        for name, expected in ARDIA_HASHES.items():
            self.assertEqual(expected, digest((source / name).read_bytes()), name)
        with tempfile.TemporaryDirectory(prefix='native-window-source-') as tmp:
            copy = Path(tmp)
            for name in set(paths(self.base) + PATHS):
                original = source / name
                if original.is_file():
                    target = copy / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(original, target)
            for patch in (BASE, PATCH):
                for flags in (['--check'], []):
                    subprocess.run(['git', 'apply', *flags, str(patch)], cwd=copy,
                                   check=True, capture_output=True, text=True)
            self.assertTrue((copy / 'ardia/core/ac_native_password_window_api_browsertest.mm').is_file())

    def test_rejects_malformed_pins_and_scope(self):
        for key, value in [('schema_version', True), ('chromium_commit', 'wrong'),
                           ('ardia_commit', 'wrong'), ('base_patch_sha256', '0' * 64),
                           ('source_ardia_sha256', {}), ('patch_sha256', '0' * 64),
                           ('patch_bytes', True), ('changed_paths', []), ('compiled', True),
                           ('accepted', True), ('integration_ready', True),
                           ('native_async_cancellation_supported', True), ('unsupported', [])]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate(dict(self.meta, **{key: value}), self.patch, self.base)
        with self.assertRaises(ValueError):
            validate(self.meta, self.patch + b'\n', self.base)
        with self.assertRaises(ValueError):
            validate(self.meta, self.patch, self.base + b'\n')


if __name__ == '__main__':
    unittest.main()
