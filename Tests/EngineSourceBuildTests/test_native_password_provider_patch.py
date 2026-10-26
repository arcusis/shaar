import hashlib
import json
import os
import pathlib
import re
import shutil
import tempfile
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / 'ThirdParty/ArdiaCore/patches/native-password-provider.patch'
CANDIDATE = PATCH.with_suffix('.candidate.json')


def validate(metadata, patch):
    required = {'schema_version', 'chromium_commit', 'chromium_version',
                'ardia_commit', 'patch_sha256', 'patch_bytes', 'changed_paths',
                'accepted', 'integration_ready', 'compiled', 'supported', 'unsupported', 'status'}
    if set(metadata) != required:
        raise ValueError('metadata keys')
    if metadata['schema_version'] != 1 or type(metadata['schema_version']) is not int:
        raise ValueError('schema')
    if metadata['chromium_commit'] != '5869fe313571d75152b77813cf0a4ee26a4e6df0':
        raise ValueError('chromium pin')
    pin = json.loads((ROOT / 'ThirdParty/ArdiaCore/pin.json').read_text())
    if (metadata['chromium_version'] != '155.0.8059.84' or
            metadata['ardia_commit'] != '91e17a5655519d2dc385ec8452432469232ff9af' or
            metadata['chromium_version'] != pin['chromiumVersion'] or
            metadata['ardia_commit'] != pin['sourceCommit']):
        raise ValueError('ardia pin')
    if (metadata['accepted'] is not False or metadata['integration_ready'] is not False
            or metadata['compiled'] is not False):
        raise ValueError('acceptance')
    if type(metadata['patch_bytes']) is not int or metadata['patch_bytes'] != len(patch):
        raise ValueError('size')
    if metadata['patch_sha256'] != hashlib.sha256(patch).hexdigest():
        raise ValueError('hash')
    text = patch.decode('utf-8')
    paths = re.findall(r'^diff --git a/(\S+) b/\1$', text, re.MULTILINE)
    allowed = {
        'ardia/core/BUILD.gn', 'ardia/core/ac_browser.h', 'ardia/core/ac_browser.mm',
        'ardia/core/ac_native_password_broker.h', 'ardia/core/ac_native_password_broker.mm',
        'ardia/core/ac_native_password_broker_browsertest.mm',
        'chrome/renderer/autofill/password_autofill_agent_browsertest.cc',
        'chrome/test/BUILD.gn', 'components/autofill/content/common/mojom/BUILD.gn',
        'components/autofill/content/common/mojom/autofill_agent.mojom',
        'components/autofill/content/renderer/password_autofill_agent.cc',
        'components/autofill/content/renderer/password_autofill_agent.h',
        'components/password_manager/content/browser/content_password_manager_driver.cc',
        'components/password_manager/content/browser/content_password_manager_driver.h',
    }
    if set(paths) != allowed or paths != metadata['changed_paths'] or len(paths) != len(set(paths)):
        raise ValueError('paths')
    if not all(isinstance(metadata[k], list) and all(isinstance(v, str) and v for v in metadata[k])
               for k in ('supported', 'unsupported')):
        raise ValueError('scope')
    if metadata['status'] != 'browser_broker_candidate_uncompiled' or len(metadata['supported']) != 2:
        raise ValueError('incomplete scope')
    return text


def compact(value):
    return re.sub(r"\s+", "", re.sub(r"(?m)^\+", "", value))


class CandidateTest(unittest.TestCase):
    def setUp(self):
        self.metadata = json.loads(CANDIDATE.read_text())
        self.patch = PATCH.read_bytes()

    def test_pin_hash_and_renderer_layers(self):
        text = validate(self.metadata, self.patch)
        for fragment in ('blink.mojom.DocumentToken', 'document.Token() != document_token',
                         'document.FocusedElement()', 'IsConnected()',
                         'GetOwningFormForAutofill()', 'GetNativeFocusedFormSnapshot()',
                         'GetOwnedAutofillableFormControls(document, form)',
                         'native_focus_generation_ != focus_generation',
                         'OnFieldAutofilled(pass)',
                         'DoFillField(user, username', 'FillPasswordFieldAndSave('):
            self.assertIn(compact(fragment), compact(text), fragment)
        self.assertGreaterEqual(text.count('if (!valid())'), 3)

    def test_driver_wrappers_forward_snapshot_and_fill(self):
        text = validate(self.metadata, self.patch)
        for fragment in ('ContentPasswordManagerDriver::GetNativeFocusedFormSnapshot',
                         'agent->GetNativeFocusedFormSnapshot(',
                         'WrapCallbackWithDefaultInvokeIfNotRun(std::move(callback)',
                         'ContentPasswordManagerDriver::FillNativePasswordSuggestion',
                         'agent->FillNativePasswordSuggestion(',
                         'snapshot.document_token, snapshot.form_id, snapshot.focused_field_id',
                         'snapshot.focus_generation, snapshot.username_field_id',
                         'snapshot.password_field_id, username, password,'):
            self.assertIn(compact(fragment), compact(text), fragment)


    def test_broker_is_connected_and_guarded(self):
        text = validate(self.metadata, self.patch)
        for fragment in ('NativePasswordBroker::Request', 'NativePasswordBroker::Consume',
                         'NativePasswordBroker::Cancel', 'GetWeakDocumentPtr()',
                         'AsRenderFrameHostIfValid() != frame',
                         'Profile::FromBrowserContext(contents->GetBrowserContext())',
                         'GetActiveWebContents() != contents',
                         'contents->GetFocusedFrame() != frame',
                         'frame->GetLastCommittedURL().SchemeIs(url::kHttpsScheme)',
                         'net::IsCertStatusError(navigation->GetSSL().cert_status)',
                         'frame->IsErrorDocument()',
                         'driver->native_focus_generation() == entry.focus_generation',
                         'driver->GetNativeFocusedFormSnapshot(',
                         'entries_.extract(handle)',
                         'driver->FillNativePasswordSuggestion(*entry.snapshot',
                         '++native_focus_generation_',
                         'NativePasswordBrokerBrowserTest, SuccessAndReplay',
                         'NativePasswordBrokerBrowserTest, RejectsChangedDocument',
                         'NativePasswordBrokerBrowserTest, RejectsFocusAwayAndBack',
                         'NativePasswordBrokerBrowserTest, RejectsHttp',
                         'NativePasswordBrokerBrowserTest, RejectsTabAwayAndBack',
                         'NativePasswordBrokerBrowserTest, RejectsProfileAwayAndBack',
                         'NativePasswordBrokerBrowserTest, PendingProfileAwayAndBackIsRejected',
                         'NativePasswordBrokerBrowserTest, PendingDestructionCompletesOnce',
                         'NativePasswordBrokerBrowserTest, PendingCancelCompletesOnce',
                         'NativePasswordBroker::CancelAll',
                         'owner->selection_generation() != entry.selection_generation',
                         'selection.active_tab_changed()', '++selection_generation_',
                         'pending_requests_.extract(request_id)',
                         'weak_factory_.InvalidateWeakPtrs()',
                         'std::move(callback).Run(std::nullopt)',
                         'mojo::WrapCallbackWithDefaultInvokeIfNotRun'):
            self.assertIn(compact(fragment), compact(text), fragment)

    def test_optional_source_application(self):
        source = os.environ.get('NATIVE_PASSWORD_PROVIDER_CHROMIUM_SOURCE')
        if not source:
            self.skipTest('NATIVE_PASSWORD_PROVIDER_CHROMIUM_SOURCE not set')
        source = pathlib.Path(source)
        revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip()
        self.assertEqual(self.metadata['chromium_commit'], revision)
        with tempfile.TemporaryDirectory(prefix='native-provider-apply-') as directory:
            copy = pathlib.Path(directory)
            for name in self.metadata['changed_paths']:
                original = source / name
                if original.is_file():
                    destination = copy / name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(original, destination)
            for args in (['--check'], []):
                subprocess.run(['git', 'apply', *args, str(PATCH)], cwd=copy,
                               check=True, capture_output=True, text=True)
            self.assertTrue((copy / 'ardia/core/ac_native_password_broker.mm').is_file())

    def test_rejects_malformed_metadata(self):
        for key, value in [('accepted', True), ('integration_ready', True), ('compiled', True),
                           ('chromium_commit', 'wrong'), ('patch_bytes', True),
                           ('patch_sha256', '0' * 64), ('changed_paths', []),
                           ('supported', [])]:
            with self.subTest(key=key):
                bad = dict(self.metadata, **{key: value})
                with self.assertRaises(ValueError):
                    validate(bad, self.patch)

    def test_rejects_tampered_patch(self):
        with self.assertRaises(ValueError):
            validate(self.metadata, self.patch + b'\n')


if __name__ == '__main__':
    unittest.main()
