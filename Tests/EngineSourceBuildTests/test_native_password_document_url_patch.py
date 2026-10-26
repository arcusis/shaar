import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCH_DIR = ROOT / 'ThirdParty/ArdiaCore/patches'
NAMES = ('native-password-provider.patch', 'native-password-window-api.patch',
         'native-password-document-url.patch')
CANDIDATE = PATCH_DIR / 'native-password-document-url.candidate.json'
DEFAULT_SOURCE = ROOT / 'build/EngineSource/chromium_git/chromium/src'
CHROMIUM = '5869fe313571d75152b77813cf0a4ee26a4e6df0'
ARDIA = '91e17a5655519d2dc385ec8452432469232ff9af'
PATCH_HASH = '1ea43339486e06f351e094f4f0be4ad9c536563ce373129b2195967186233ad6'
PREREQUISITES = {
    NAMES[0]: '45062b8a0877217160482cd1c8374cd8d714484213d762397b5728816ba7576c',
    NAMES[1]: '5686f1a15aefadf3a57a718410ae4a8b2683d0dabe55fd0bdc5ac11b6edf8a3b',
}
SOURCE_HASHES = {'ardia/core/BUILD.gn': '4308ed17c4ea07ecdb4cbded04d741420e636ac643bb4956b75f9d6b56b795e0',
 'ardia/core/ac_browser.h': 'b17c02666132bb5896c4c7d7481404d11fa5163ece448b456405aee4b247626b',
 'ardia/core/ac_browser.mm': 'e16265e4b3143ab3dde69638a12d68a49cde2dfb5521486c946df39418b580f4',
 'ardia/core/ardiacore_api.mm': '252badb5e6370dad44e9d1d61c715e5383d4cf4f073e4f31c5bad6b9909a2afa',
 'ardia/core/public/ArdiaCore.h': '0fd7373014b0180a95e17cf4f46cf0aa4dc711e14bc022dde62cc765f335ef1c',
 'chrome/renderer/autofill/password_autofill_agent_browsertest.cc': 'd63062065615a407a4907ca14e3dfea6b17ca026cc500598c03b900c56777769',
 'chrome/test/BUILD.gn': '4b1c4e75e9298e44953d57c11d3aeb12dee6b036b6f9071a887d3a7cc213e832',
 'components/autofill/content/common/mojom/BUILD.gn': '90815656d3b01d9a490a6e408c6b091e1d2c61d18bcefb500683cc35fbe43aaa',
 'components/autofill/content/common/mojom/autofill_agent.mojom': '6796cc571a0a5c751209089bfd33ad124beb11f1627363d7f1c42ed4a7bdbabc',
 'components/autofill/content/renderer/password_autofill_agent.cc': '0462bb28c2fe91cbe13c52bedf1dda2101bb8986128c9d4f52ffcb0e0e8c75cb',
 'components/autofill/content/renderer/password_autofill_agent.h': '2d03645bf9f4a7f90c779adf4d7212fecd27a64304b1806ff3759619af68ddfa',
 'components/password_manager/content/browser/content_password_manager_driver.cc': '62cbe639f5ea10a36ec1f196a96f7948fc9189f910e045cead2ff49dc7776c3f',
 'components/password_manager/content/browser/content_password_manager_driver.h': 'bcbc4c4f7948016cb09ecc3c73493898fdc0ec4abab5c3997f2fcccdccab16f5'}
PATHS = ['ardia/core/ac_native_password_broker.h',
 'ardia/core/ac_native_password_broker.mm',
 'ardia/core/ac_native_password_broker_browsertest.mm',
 'ardia/core/ac_native_password_window_api_browsertest.mm',
 'ardia/core/ardiacore_api.mm',
 'ardia/core/public/ArdiaCore.h',
 'chrome/renderer/autofill/password_autofill_agent_browsertest.cc',
 'components/autofill/content/common/mojom/autofill_agent.mojom',
 'components/autofill/content/renderer/password_autofill_agent.cc',
 'components/autofill/content/renderer/password_autofill_agent.h',
 'components/password_manager/content/browser/content_password_manager_driver.cc']


def digest(data):
    return hashlib.sha256(data).hexdigest()


def patch_paths(data):
    return re.findall(r'^diff --git a/(\S+) b/\1$', data.decode(), re.M)


def validate(meta, patches):
    required = {'schema_version', 'chromium_commit', 'chromium_version',
                'ardia_commit', 'prerequisite_patch_sha256', 'source_sha256',
                'patch_sha256', 'patch_bytes', 'changed_paths', 'compiled',
                'accepted', 'integration_ready', 'supported', 'unsupported', 'status'}
    if set(meta) != required or type(meta['schema_version']) is not int or meta['schema_version'] != 1:
        raise ValueError('metadata schema')
    pin = json.loads((ROOT / 'ThirdParty/ArdiaCore/pin.json').read_text())
    if (meta['chromium_commit'] != CHROMIUM or meta['ardia_commit'] != ARDIA or
            meta['chromium_version'] != '155.0.8059.84' or
            pin['sourceCommit'] != ARDIA or pin['chromiumVersion'] != meta['chromium_version']):
        raise ValueError('source pins')
    if meta['prerequisite_patch_sha256'] != PREREQUISITES or any(
            digest(patches[name]) != expected for name, expected in PREREQUISITES.items()):
        raise ValueError('prerequisite patch')
    if meta['source_sha256'] != SOURCE_HASHES:
        raise ValueError('source hashes')
    patch = patches[NAMES[-1]]
    if (type(meta['patch_bytes']) is not int or meta['patch_bytes'] != len(patch) or
            meta['patch_sha256'] != PATCH_HASH or digest(patch) != PATCH_HASH):
        raise ValueError('patch hash')
    if meta['changed_paths'] != PATHS or patch_paths(patch) != PATHS:
        raise ValueError('patch scope')
    if any(meta[key] is not False for key in ('compiled', 'accepted', 'integration_ready')):
        raise ValueError('acceptance')
    if (meta['status'] != 'native_document_url_candidate_uncompiled' or
            not isinstance(meta['supported'], list) or not meta['supported'] or
            not isinstance(meta['unsupported'], list) or
            'older frameworks lack documentURL; adapter must check availability and fail closed for URL-specific policy' not in meta['unsupported']):
        raise ValueError('limits')


def verify_source(copy_root):
    for name, expected in SOURCE_HASHES.items():
        if digest((copy_root / name).read_bytes()) != expected:
            raise ValueError('source hash: ' + name)


def copy_pinned_baseline(source, ardia_source, target):
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip()
    if revision != CHROMIUM:
        raise ValueError('chromium revision')
    for name in SOURCE_HASHES:
        if name.startswith('ardia/'):
            revision_path = f'{ARDIA}:engine/ardiacore/src/{name}'
            repository = ardia_source
        else:
            revision_path = f'{CHROMIUM}:{name}'
            repository = source
        # Both shared checkouts may be dirty; use only pinned Git objects.
        data = subprocess.check_output(['git', 'show', revision_path], cwd=repository)
        destination = target / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
    verify_source(target)


class NativePasswordDocumentURLPatchTests(unittest.TestCase):
    def setUp(self):
        self.meta = json.loads(CANDIDATE.read_text())
        self.patches = {name: (PATCH_DIR / name).read_bytes() for name in NAMES}

    def test_pins_and_scope(self):
        validate(self.meta, self.patches)

    def test_tampering_rejected(self):
        for key, value in [('schema_version', True), ('chromium_commit', 'wrong'),
                           ('ardia_commit', 'wrong'), ('prerequisite_patch_sha256', {}),
                           ('source_sha256', {}), ('patch_sha256', '0' * 64),
                           ('patch_bytes', True), ('changed_paths', []),
                           ('compiled', True), ('accepted', True),
                           ('integration_ready', True), ('unsupported', [])]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate(dict(self.meta, **{key: value}), self.patches)
        altered_patch = self.patches[NAMES[-1]] + b'\n'
        altered_meta = dict(self.meta, patch_sha256=digest(altered_patch), patch_bytes=len(altered_patch))
        with self.assertRaises(ValueError):
            validate(altered_meta, dict(self.patches, **{NAMES[-1]: altered_patch}))
        for name in NAMES:
            altered = dict(self.patches, **{name: self.patches[name] + b'\n'})
            with self.subTest(patch=name), self.assertRaises(ValueError):
                validate(self.meta, altered)

    def test_sequential_application_to_pinned_minimal_source(self):
        validate(self.meta, self.patches)
        source = Path(os.environ.get('NATIVE_PASSWORD_DOCUMENT_URL_CHROMIUM_SOURCE', DEFAULT_SOURCE))
        if not source.is_dir():
            if 'NATIVE_PASSWORD_DOCUMENT_URL_CHROMIUM_SOURCE' in os.environ:
                self.fail('explicit pinned source unavailable')
            self.skipTest('pinned source unavailable')
        ardia_source = Path(os.environ.get(
            'NATIVE_PASSWORD_DOCUMENT_URL_ARDIA_SOURCE',
            source.parents[2] / 'source/ardia'))
        if not ardia_source.is_dir():
            if ('NATIVE_PASSWORD_DOCUMENT_URL_ARDIA_SOURCE' in os.environ or
                    'NATIVE_PASSWORD_DOCUMENT_URL_CHROMIUM_SOURCE' in os.environ):
                self.fail('explicit pinned Ardia source unavailable')
            self.skipTest('pinned Ardia source unavailable')
        with tempfile.TemporaryDirectory(prefix='native-document-url-') as tmp:
            target = Path(tmp)
            copy_pinned_baseline(source, ardia_source, target)
            for name in SOURCE_HASHES:
                victim = target / name
                original = victim.read_bytes()
                victim.write_bytes(original + b'\n')
                with self.subTest(source=name), self.assertRaisesRegex(
                        ValueError, 'source hash:'):
                    verify_source(target)
                victim.write_bytes(original)
            verify_source(target)
            # Avoid git apply silently skipping paths when TMPDIR is inside a
            # different repository, and verify every advertised path changed.
            subprocess.run(['git', 'init', '-q'], cwd=target, check=True,
                           capture_output=True, text=True)
            for name in NAMES:
                paths = patch_paths(self.patches[name])
                self.assertTrue(paths, name)
                before = {path: (target / path).read_bytes() if (target / path).is_file()
                          else None for path in paths}
                for args in (['--check'], []):
                    subprocess.run(['git', 'apply', *args, str(PATCH_DIR / name)],
                                   cwd=target, check=True, capture_output=True, text=True)
                for path in paths:
                    with self.subTest(patch=name, path=path):
                        self.assertTrue((target / path).is_file())
                        self.assertNotEqual(before[path], (target / path).read_bytes())


if __name__ == '__main__':
    unittest.main()
