import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
PRODUCTION = ROOT
SPEC = importlib.util.spec_from_file_location('sdk10_builder', ROOT / 'scripts/build-native-bitwarden-strict-sdk.py')
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


def read(path, expected):
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != expected:
        raise ValueError('fixture digest mismatch')
    return json.loads(raw, object_pairs_hook=BUILDER.unique_object)


class SDK10PinTests(unittest.TestCase):
    def setUp(self):
        base = read(ROOT / 'ThirdParty/BitwardenStrictEditSpike/sdk-package.pin.json', BUILDER.SDK8_PIN_SHA256)
        service = read(PRODUCTION / 'ThirdParty/BitwardenStrictEditSpike/service-sdk-package.pin.json', BUILDER.SERVICE_PIN_SHA256)
        service_candidate = read(PRODUCTION / 'ThirdParty/BitwardenStrictEditSpike/strict-service-shapes.candidate.json', BUILDER.SERVICE_CANDIDATE_SHA256)
        self.sdk9 = BUILDER.validate_service_pin(service, base, service_candidate)
        self.pin = read(ROOT / 'ThirdParty/BitwardenStrictEditSpike/normalization-sdk-package.pin.json', BUILDER.NORMALIZATION_PIN_SHA256)
        self.candidate = read(ROOT / 'ThirdParty/BitwardenStrictEditSpike/strict-normalization.candidate.json', BUILDER.NORMALIZATION_CANDIDATE_SHA256)

    def test_exact_sdk9_ancestry_and_one_change(self):
        before = copy.deepcopy(self.sdk9)
        result = BUILDER.validate_normalization_pin(self.pin, self.candidate, self.sdk9)
        self.assertEqual(self.sdk9, before)
        self.assertEqual(result['candidateGitTree'], BUILDER.NORMALIZATION_TREE)
        self.assertEqual(result['sourceManifestSHA256'], BUILDER.NORMALIZATION_MANIFEST)
        self.assertEqual(result['changedPaths'], self.sdk9['changedPaths'])
        self.assertEqual(result['patches'][:-1], self.sdk9['patches'])
        self.assertEqual(result['changedSourceSHA256'][BUILDER.NORMALIZATION_PATH], BUILDER.NORMALIZATION_FILE_SHA256)
        self.assertEqual(result['candidateCargoLockSHA256'], self.sdk9['candidateCargoLockSHA256'])

    def test_incorrect_sdk8_based_tree_rejected(self):
        pin = copy.deepcopy(self.pin)
        pin['candidateTree'] = 'eac2fbcbdb03e397cc3a0ea51e2eef6019c3bc0a'
        with self.assertRaises(ValueError): BUILDER.validate_normalization_pin(pin, self.candidate, self.sdk9)

    def test_candidate_and_pin_tampering(self):
        for key, value in [('patchSHA256', '0' * 64), ('changedPath', '../escape'),
                           ('sourceManifestSHA256', '0' * 64), ('fullDiffSHA256', 'f' * 64),
                           ('sourceManifestEntries', True), ('integrationReady', True)]:
            candidate = copy.deepcopy(self.candidate)
            candidate[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                BUILDER.validate_normalization_pin(self.pin, candidate, self.sdk9)

    def test_unknown_and_missing_fields_rejected(self):
        for change in ('missing', 'extra'):
            pin = copy.deepcopy(self.pin)
            if change == 'missing': del pin['sdk9PinSHA256']
            else: pin['extra'] = 'unreviewed'
            with self.assertRaises(ValueError): BUILDER.validate_normalization_pin(pin, self.candidate, self.sdk9)

    def test_changed_sdk9_parent_rejected(self):
        baseline = copy.deepcopy(self.sdk9)
        baseline['candidateGitTree'] = '0' * 40
        with self.assertRaises(ValueError): BUILDER.validate_normalization_pin(self.pin, self.candidate, baseline)

    def test_sdk10_hosted_mode_is_explicit_and_exclusive(self):
        self.assertTrue(BUILDER.hosted_input_profile(BUILDER.SDK10_PROFILE, (None, None), ('x',) * 6))
        with self.assertRaises(ValueError):
            BUILDER.hosted_input_profile(BUILDER.SDK10_PROFILE, ('registry', None), ('x',) * 6)
        with self.assertRaises(ValueError):
            BUILDER.hosted_input_profile(BUILDER.SDK10_PROFILE, (None, None), ('x',) * 5 + (None,))
        self.assertFalse(BUILDER.hosted_input_profile(BUILDER.SDK10_PROFILE, ('registry', 'git'), (None,) * 6))

    def test_transition_requires_one_exact_path_and_blob(self):
        output = [BUILDER.NORMALIZATION_PATH + '\n', 'fixed-source']
        with patch.object(BUILDER, 'run', side_effect=output), patch.object(BUILDER, 'NORMALIZATION_FILE_SHA256', hashlib.sha256(b'fixed-source').hexdigest()):
            BUILDER.verify_normalization_transition(None, Path('/tmp/sdk'), {})
        with patch.object(BUILDER, 'run', return_value='unexpected\n'):
            with self.assertRaises(ValueError): BUILDER.verify_normalization_transition(None, Path('/tmp/sdk'), {})

    def test_diff_contract_rejects_content_and_path_mismatch(self):
        expected = b'fixed diff\n'
        pin = {'candidateGitTree': 'a' * 40, 'fullDiffSHA256': hashlib.sha256(expected).hexdigest(),
               'changedPaths': ['file']}
        calls = []

        def git(*args):
            calls.append(args)
            if '--binary' in args:
                return expected.decode()
            if '--name-only' in args:
                return 'file\n'
            if args == ('--version',):
                return 'git version synthetic\n'
            raise AssertionError(args)

        BUILDER.verify_source_diff(git, pin)
        self.assertNotIn('--abbrev=8', calls[0])
        calls.clear()
        with redirect_stdout(io.StringIO()) as output:
            BUILDER.verify_source_diff(git, pin, hosted_sdk10=True)
        self.assertIn('--abbrev=8', calls[0])
        diagnostic = json.loads(output.getvalue())
        self.assertEqual(diagnostic['sourceDiffSHA256'], pin['fullDiffSHA256'])
        self.assertEqual(diagnostic['changedPathCount'], 1)
        self.assertTrue(diagnostic['changedPathsMatch'])
        self.assertEqual(diagnostic['gitVersion'], 'git version synthetic')
        for key, value in (('fullDiffSHA256', '0' * 64), ('changedPaths', ['other'])):
            broken = dict(pin, **{key: value})
            with redirect_stdout(io.StringIO()), self.assertRaisesRegex(ValueError, 'source diff mismatch'):
                BUILDER.verify_source_diff(git, broken, hosted_sdk10=True)

    def test_explicit_abbreviation_ignores_git_configuration(self):
        with tempfile.TemporaryDirectory() as temp:
            env = {'PATH': '/usr/bin:/bin', 'HOME': temp, 'LC_ALL': 'C',
                   'GIT_CONFIG_NOSYSTEM': '1', 'GIT_TERMINAL_PROMPT': '0'}

            def git(*args, input=None):
                return subprocess.run(['/usr/bin/git', *args], cwd=temp, env=env, input=input,
                                      text=True, capture_output=True, check=True).stdout

            git('init', '--quiet')
            old = git('hash-object', '-w', '--stdin', input='old\n').strip()
            new = git('hash-object', '-w', '--stdin', input='new\n').strip()
            before = git('mktree', input=f'100644 blob {old}\tfile\n').strip()
            after = git('mktree', input=f'100644 blob {new}\tfile\n').strip()
            diff = ('diff', '--no-ext-diff', '--no-textconv', '--binary')
            implicit7 = git('-c', 'core.abbrev=7', *diff, before, after)
            implicit12 = git('-c', 'core.abbrev=12', *diff, before, after)
            explicit7 = git('-c', 'core.abbrev=7', *diff, '--abbrev=8', before, after)
            explicit12 = git('-c', 'core.abbrev=12', *diff, '--abbrev=8', before, after)
            self.assertNotEqual(implicit7, implicit12)
            self.assertEqual(explicit7, explicit12)


if __name__ == '__main__':
    unittest.main()
