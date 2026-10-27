import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCH_DIR = ROOT / "ThirdParty/ArdiaCore/patches"
WORK = ROOT / "build/NativePasswordSubmissionV2"
CHROMIUM_SOURCE = None
ARDIA_SOURCE = None
CHROMIUM = "5869fe313571d75152b77813cf0a4ee26a4e6df0"
ARDIA = "91e17a5655519d2dc385ec8452432469232ff9af"
PATCH_HASH = '7e98a253bf45df3c51e2f0b4b1d4a709367227d82c2179655a5862d4187f8c68'
PATCH_BYTES = 59269
PREREQUISITES = {'native-password-provider.patch': '45062b8a0877217160482cd1c8374cd8d714484213d762397b5728816ba7576c',
 'native-password-window-api.patch': '5686f1a15aefadf3a57a718410ae4a8b2683d0dabe55fd0bdc5ac11b6edf8a3b',
 'native-password-document-url.patch': '1ea43339486e06f351e094f4f0be4ad9c536563ce373129b2195967186233ad6'}
SOURCE_HASHES = {'ardia/core/BUILD.gn': '4308ed17c4ea07ecdb4cbded04d741420e636ac643bb4956b75f9d6b56b795e0',
 'ardia/core/ac_browser.h': 'b17c02666132bb5896c4c7d7481404d11fa5163ece448b456405aee4b247626b',
 'ardia/core/ac_browser.mm': 'e16265e4b3143ab3dde69638a12d68a49cde2dfb5521486c946df39418b580f4',
 'ardia/core/ardiacore_api.mm': '252badb5e6370dad44e9d1d61c715e5383d4cf4f073e4f31c5bad6b9909a2afa',
 'ardia/core/public/ArdiaCore.h': '0fd7373014b0180a95e17cf4f46cf0aa4dc711e14bc022dde62cc765f335ef1c',
 'chrome/browser/password_manager/chrome_password_manager_client.cc': '3e8375b49448d170ee0b0ca494fe3ce708ba1fb71c4084ad9a2bfd4b203aee56',
 'chrome/browser/password_manager/chrome_password_manager_client.h': '235bc6f4198af3c895513c5218c309165535171b8f4edd6dc75072c6ca546a9b',
 'chrome/renderer/autofill/password_autofill_agent_browsertest.cc': 'd63062065615a407a4907ca14e3dfea6b17ca026cc500598c03b900c56777769',
 'chrome/test/BUILD.gn': '4b1c4e75e9298e44953d57c11d3aeb12dee6b036b6f9071a887d3a7cc213e832',
 'components/autofill/content/common/mojom/BUILD.gn': '90815656d3b01d9a490a6e408c6b091e1d2c61d18bcefb500683cc35fbe43aaa',
 'components/autofill/content/common/mojom/autofill_agent.mojom': '6796cc571a0a5c751209089bfd33ad124beb11f1627363d7f1c42ed4a7bdbabc',
 'components/autofill/content/renderer/password_autofill_agent.cc': '0462bb28c2fe91cbe13c52bedf1dda2101bb8986128c9d4f52ffcb0e0e8c75cb',
 'components/autofill/content/renderer/password_autofill_agent.h': '2d03645bf9f4a7f90c779adf4d7212fecd27a64304b1806ff3759619af68ddfa',
 'components/password_manager/content/browser/content_password_manager_driver.cc': '62cbe639f5ea10a36ec1f196a96f7948fc9189f910e045cead2ff49dc7776c3f',
 'components/password_manager/content/browser/content_password_manager_driver.h': 'bcbc4c4f7948016cb09ecc3c73493898fdc0ec4abab5c3997f2fcccdccab16f5',
 'components/password_manager/core/browser/credential_manager_impl.cc': 'ac00d46d170a0cb12695d6b58dcd8489f6aa01fb3ffbbefab8037be331bd6acf',
 'components/password_manager/core/browser/credential_manager_impl.h': '11eb731b67afbf61cff3ac711b43f1c9751f44539e7403795420f4c7d44edf3e',
 'components/password_manager/core/browser/credential_manager_pending_prevent_silent_access_task.cc': '916942ec0849afc6c069d9ab4dc863f30281e60fd9ce01d59e6662ef53dd3027',
 'components/password_manager/core/browser/credential_manager_pending_prevent_silent_access_task.h': 'e239a2d41e7d832249ea465794da0557fed188eccd7912e860300dcae2a58262',
 'components/password_manager/core/browser/http_auth_manager_impl.cc': '003789d92b7bfc47e4b4eb1218cc420ccd604e3b7a306623eac8a47bef854ba4',
 'components/password_manager/core/browser/password_form_manager.cc': '1e9b39900874ef2731dd50ec5b44015a6759cdb6d02cfba4dec87d4643c77d52',
 'components/password_manager/core/browser/password_form_manager.h': '8a3bd82c31fa9acc7c3c212ffde7a02f66a4e660c32d13f2153061c4a2b3303d',
 'components/password_manager/core/browser/password_manager.cc': '1521a5c1e878a32bf3f3a73ea4f4572f4ed645c3c74c6efcc03965461011d563',
 'components/password_manager/core/browser/password_manager_client.h': '3c6b55a4ea8b75508081ae6dca9225a62de00e73b3354280cb93de4ba82a31dc'}
CHANGED_PATHS = ['ardia/core/ac_browser.h',
 'ardia/core/ac_browser.mm',
 'ardia/core/ac_native_password_broker.h',
 'ardia/core/ac_native_password_broker.mm',
 'chrome/browser/password_manager/chrome_password_manager_client.cc',
 'chrome/browser/password_manager/chrome_password_manager_client.h',
 'components/password_manager/core/browser/credential_manager_impl.cc',
 'components/password_manager/core/browser/credential_manager_impl.h',
 'components/password_manager/core/browser/credential_manager_pending_prevent_silent_access_task.cc',
 'components/password_manager/core/browser/credential_manager_pending_prevent_silent_access_task.h',
 'components/password_manager/core/browser/http_auth_manager_impl.cc',
 'components/password_manager/core/browser/password_form_manager.cc',
 'components/password_manager/core/browser/password_form_manager.h',
 'components/password_manager/core/browser/password_manager.cc',
 'components/password_manager/core/browser/password_manager_client.h']
RESULT_HASHES = {'ardia/core/ac_browser.h': '82de7ab6db425f9acda1d7d86431659f64bbd9b29f0a3793c43cfd390cbd0ae5',
 'ardia/core/ac_browser.mm': '8510a633f5a5a910d426a0ce2c8ff751186feed6757ef94fe57b8d493469bbcc',
 'ardia/core/ac_native_password_broker.h': 'd88ca925f09943c57e3d120bd0171aece6aecaf2b940f5d2f489a4c28c83a783',
 'ardia/core/ac_native_password_broker.mm': '05dcae8e0a4feb33844c3487be0c56be9b9825a4c396fab0766d07b2b592227e',
 'chrome/browser/password_manager/chrome_password_manager_client.cc': '852328e8b0348d1087785868945e6f420d50ca8f8f8895d77c1970ecbf9eab0a',
 'chrome/browser/password_manager/chrome_password_manager_client.h': '436ffd45b185bd3937120760a92423ac12f32715c3c8de3bdaccc7874c02d146',
 'components/password_manager/core/browser/credential_manager_impl.cc': '24f132f5b990d088bf8ce6fc72233b68476fe3823cdf9970ebed9a16f18a48ed',
 'components/password_manager/core/browser/credential_manager_impl.h': 'a3915270c5ca2a956930c6923b240305d68361553e8f6307a7c00fdcc906c7d1',
 'components/password_manager/core/browser/credential_manager_pending_prevent_silent_access_task.cc': 'fd2f1acf9aa3218cbaaca917116fd5980c3c04db0eb1c7407fc330f5ba82045b',
 'components/password_manager/core/browser/credential_manager_pending_prevent_silent_access_task.h': 'a54472e42544365fe79046c787197af4e222708ba76b261a3517e21172e94a09',
 'components/password_manager/core/browser/http_auth_manager_impl.cc': '36800fe2e3f860b51bd6eb372bdb2f2cc48d80b3f974a15a80b09340e8d5c254',
 'components/password_manager/core/browser/password_form_manager.cc': '7202dd88251dd972e8a3508044e95a3b100f2e5b6913972e12b13dbbec8eb750',
 'components/password_manager/core/browser/password_form_manager.h': '54ad80df5bd29760364dd2ef34b0f0651e25fc9311cab12970f66884b3ddba09',
 'components/password_manager/core/browser/password_manager.cc': '366212e6ce3396e84445fe664dd62ec3ad34f217cf7562789244a4f99c7acb32',
 'components/password_manager/core/browser/password_manager_client.h': '25c4d752964ff831bac11210d59ec5b8943e5bbb0602e6650cf112fcff1e1c05'}
INTERFACE_HASHES = {'components/password_manager/core/browser/form_fetcher.h': '8c953c8d5624937c4581f530ebd8d9501d754ec41a498599502f7d761154e2a3',
 'components/password_manager/core/browser/form_fetcher_impl.cc': 'b5e01c288da5837c34eb49633f7a1a5449b49805e6f44bbce1200075d45a1fa1',
 'components/password_manager/core/browser/form_saver.h': '6124425d7e0f3a9ceafc390d8bb0661fa89a5a83df1eea71c2c2c9069860a17b',
 'components/password_manager/core/browser/password_save_manager_impl.h': 'd060e154405eb9b1f5a2e56e2b9848fad330efd29ddace33f58b30f07d325565',
 'components/password_manager/core/browser/password_save_manager_impl.cc': 'fa6aad8224bb1e5870045a33b08cba878af3408e847c929be0d82fa150029de3',
 'chrome/browser/profiles/profile.h': 'dc1ff74874ce73db6eeb579ed9b5a85a3226387ce3a4172eb814336562634485',
 'chrome/browser/profiles/profile_observer.h': '798930db369924dea163b7f1855688abe7899614b31d715fa6239251c195a241',
 'chrome/browser/profiles/profile.cc': 'f8999e49c117b11bbf720397f284434f87fd8f431f9dae6353c501d2a699ad31',
 'base/scoped_observation.h': '406257977df2006bd2046320066a8fbf4a8d183981541f24d99196d0eb3677f4',
 'content/public/browser/browser_thread.h': '2fc11786b55e672806e941347fe7af7c202e4abef5a4826079260e916c848e8c'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def read_metadata(data):
    return json.loads(data, object_pairs_hook=unique_object)


def patch_paths(data):
    return re.findall(r"^diff --git a/(\S+) b/\1$", data.decode(), re.M)


def validate_metadata(meta, blobs):
    keys = {"schema_version", "chromium_commit", "chromium_version", "ardia_commit",
            "prerequisite_patch_sha256", "source_sha256", "patch_sha256", "patch_bytes",
            "changed_paths", "result_sha256", "compiled", "accepted", "integration_ready",
            "status", "supported", "unsupported"}
    if set(meta) != keys or type(meta["schema_version"]) is not int or meta["schema_version"] != 1:
        raise ValueError("schema")
    if (meta["chromium_commit"] != CHROMIUM or meta["ardia_commit"] != ARDIA or
            meta["chromium_version"] != "155.0.8059.84"):
        raise ValueError("source pins")
    if meta["prerequisite_patch_sha256"] != PREREQUISITES or any(
            digest(blobs[name]) != expected for name, expected in PREREQUISITES.items()):
        raise ValueError("prerequisite")
    patch = blobs["native-password-submission.patch"]
    if (meta["source_sha256"] != SOURCE_HASHES or meta["result_sha256"] != RESULT_HASHES or
            meta["patch_sha256"] != PATCH_HASH or digest(patch) != PATCH_HASH or
            type(meta["patch_bytes"]) is not int or meta["patch_bytes"] != PATCH_BYTES or
            len(patch) != PATCH_BYTES or meta["changed_paths"] != CHANGED_PATHS or
            patch_paths(patch) != CHANGED_PATHS):
        raise ValueError("patch or path pin")
    if any(meta[name] is not False for name in ("compiled", "accepted", "integration_ready")):
        raise ValueError("acceptance claim")
    if meta["status"] != "native_submission_source_candidate_uncompiled":
        raise ValueError("status")
    if not isinstance(meta["supported"], list) or not meta["supported"]:
        raise ValueError("supported scope")
    if not isinstance(meta["unsupported"], list) or not any(
            "profile-wide store-dispatch barrier" in item and "renderer logging" in item
            for item in meta["unsupported"]):
        raise ValueError("unproven barriers")


def section(text, start, end):
    if text.count(start) != 1:
        raise ValueError("missing section: " + start)
    tail = text.split(start, 1)[1]
    if end not in tail:
        raise ValueError("missing section end: " + end)
    return tail.split(end, 1)[0]


def require(text, *needles):
    if any(needle not in text for needle in needles):
        raise ValueError("missing static guard")


def validate_static(sources):
    broker = sources["ardia/core/ac_native_password_broker.mm"]
    broker_h = sources["ardia/core/ac_native_password_broker.h"]
    manager = sources["components/password_manager/core/browser/password_manager.cc"]
    form = sources["components/password_manager/core/browser/password_form_manager.cc"]
    client = sources["chrome/browser/password_manager/chrome_password_manager_client.cc"]
    cma = sources["components/password_manager/core/browser/credential_manager_impl.cc"]
    mediation = sources["components/password_manager/core/browser/credential_manager_pending_prevent_silent_access_task.cc"]
    http_auth = sources["components/password_manager/core/browser/http_auth_manager_impl.cc"]
    owner = sources["ardia/core/ac_browser.mm"]
    interface = sources["components/password_manager/core/browser/password_manager_client.h"]
    client_h = sources["chrome/browser/password_manager/chrome_password_manager_client.h"]
    require(interface, "virtual bool NativePasswordOnlyPolicy() const { return false; }",
            "virtual bool NativeCaptureAllowed")
    require(form, "class NativeEmptyFormFetcher final : public FormFetcher",
            "generations_.at(consumer)", "std::make_unique<NativeEmptyFormFetcher>()",
            "possible_username.signon_realm != parsed_submitted_form_->signon_realm")
    require(manager, "class NativeNoWriteFormSaver final : public FormSaver",
            "std::make_unique<NativeNoWriteFormSaver>()", "ResetNativeSubmissionNonce()",
            "NativeSubmissionPrepared(driver, submitted_form, *matched_manager)",
            "NativeSubmissionInferred(*manager)")
    require(client, "NativePasswordProfilePolicy", "NativePasswordOnlyPolicy()",
            "SetNativePasswordOnlyPolicyForTesting", "entry->GetSSL().certificate",
            "IsPasswordManagementEnabledForCurrentPage(url)")
    require(client, "std::shared_ptr<NativePasswordPolicyState> state",
            "base::ScopedObservation<Profile, ProfileObserver> observation",
            "void OnProfileWillBeDestroyed(Profile*) override", "state->retired = true;",
            "CHECK_CURRENTLY_ON(content::BrowserThread::UI);",
            "native_policy_state_ = native_policy;")
    require(client_h, "std::shared_ptr<void> native_policy_state_;")
    transition = section(client, "void ChromePasswordManagerClient::SetNativePasswordOnlyPolicyForTesting(",
                         "void ChromePasswordManagerClient::SetNativeSubmissionCallbacks(")
    require(transition, "const auto profile_alive = profile->GetWeakPtr();",
            "const auto clients = state->clients;", "if (state->transitioning)",
            "state->reentered = true;", "state->capture_blocked = true;",
            "if (!profile_alive || state->retired) break;", "state->transitioning = false;")
    if transition.count("for (auto client : clients)") != 2 or "for (auto& client : state->clients)" in transition:
        raise ValueError("transition snapshot")
    session = section(client, "bool ChromePasswordManagerClient::NativeCaptureSessionAllowed() const",
                      "bool ChromePasswordManagerClient::NativeCaptureAllowed(")
    require(session, "!state->retired", "!state->transitioning", "!state->capture_blocked")
    require(broker, "client->NativeCaptureSessionAllowed()")
    fetcher = section(form, "class NativeEmptyFormFetcher final : public FormFetcher",
                      "// Number of fields that recently had user input")
    require(fetcher, "AddConsumer(Consumer* consumer) override",
            "RemoveConsumer(Consumer* consumer) override", "void Fetch() override",
            "State GetState() const override", "GetInteractionsStats() const override",
            "GetInsecureCredentials() const override", "GetNonFederatedMatches() const override",
            "GetFederatedMatches() const override", "IsBlocklisted() const override",
            "IsMovingBlocked(const signin::GaiaIdHash&, const std::u16string&) const override",
            "GetAllRelevantMatches() const override", "GetBestMatches() const override",
            "GetPreferredMatch() const override", "GetPreferredOrPotentialMatchedFormType() const override",
            "std::unique_ptr<FormFetcher> Clone() override", "GetProfileStoreBackendError() const override",
            "GetAccountStoreBackendError() const override")
    saver = section(manager, "class NativeNoWriteFormSaver final : public FormSaver",
                    "// Shorten the name to spare line breaks.")
    require(saver, "PasswordForm Blocklist(PasswordFormDigest) override",
            "void Unblocklist(const PasswordFormDigest&) override",
            "void Save(PasswordForm,", "void Update(PasswordForm,",
            "void UpdateWithoutPostProcessing(PasswordForm) override",
            "void UpdateReplace(PasswordForm,", "void Remove(const PasswordForm&) override",
            "std::unique_ptr<FormSaver> Clone() override")
    require(manager, "std::make_unique<PasswordSaveManagerImpl>(\n                std::make_unique<NativeNoWriteFormSaver>(), nullptr)")
    require(cma, "NativePasswordOnlyPolicy() ||", "!client_->NativePasswordOnlyPolicy() &&",
            "CredentialManagerImpl::NativePasswordOnlyPolicy() const")
    require(mediation, "!delegate_->NativePasswordOnlyPolicy()")
    require(http_auth, "client_->NativePasswordOnlyPolicy()", "OnLoginSuccesfull()")
    owner_advance = section(owner, "bool WindowHost::AdvanceSelectionGeneration()",
                            "void WindowHost::SetActiveProfile(")
    require(owner_advance, "callbacks->Notify()", "return !!alive;")
    if owner.count("++selection_generation_;") != 1 or owner.count("AdvanceSelectionGeneration()) return;") != 4:
        raise ValueError("owner transition coverage")
    require(broker_h, "class AccountLease", "callbacks->Notify()", "document_binding",
            "password_manager::PasswordString password")
    prepared = section(broker, "void NativePasswordBroker::PreparedSubmission(",
                       "void NativePasswordBroker::InferredSubmission(")
    require(prepared, "Driver::GetForRenderFrameHost(frame) != driver", "form.global_id()",
            "frame->GetWeakDocumentPtr()", "password_fields != 1", "field.value().size() >= 1024",
            "url::Origin::Create(form.action())")
    inferred = section(broker, "void NativePasswordBroker::InferredSubmission(",
                       "void NativePasswordBroker::ExpireSave(")
    require(inferred, "manager.native_submission_nonce() != prepared_save_->manager_nonce",
            "form_data.global_id() != prepared_save_->form_id", "Event::HTML_FORM_SUBMISSION",
            "Event::XHR_SUCCEEDED", "Event::SAME_DOCUMENT_NAVIGATION",
            "prepared_save_->original_origin", "form.password_value")
    if "GetWeakDocumentPtr" in inferred or "AsRenderFrameHostIfValid" in inferred:
        raise ValueError("post-navigation original document access")
    consent = section(broker, "void NativePasswordBroker::ConfirmSaveOffer(",
                      "bool NativePasswordBroker::Valid(")
    require(consent, "std::move(pending_save_)", "pending_save_.reset()", "SaveLeaseValid()",
            "offer->nonce != nonce", "displayed_original_origin", "offer->expires")
    arm = section(broker, "bool NativePasswordBroker::ArmSaveCapture(",
                  "void NativePasswordBroker::RevokeSaveCapture()")
    require(arm, "save_owner_subscription_ =",
            "save_account_subscription_ = lease->invalidations().Add(")
    require(broker, "void NativePasswordBroker::RevokeSaveCapture()", "RevokeSaveCapture();")


class NativePasswordSubmissionPatchTests(unittest.TestCase):
    def setUp(self):
        self.meta = read_metadata((PATCH_DIR / "native-password-submission.candidate.json").read_text())
        self.blobs = {name: (PATCH_DIR / name).read_bytes() for name in PREREQUISITES}
        self.blobs["native-password-submission.patch"] = (PATCH_DIR / "native-password-submission.patch").read_bytes()

    def test_exact_pins_and_review_boundaries(self):
        validate_metadata(self.meta, self.blobs)
        with self.assertRaisesRegex(ValueError, "duplicate JSON"):
            read_metadata('{"schema_version":1,"schema_version":1}')
        for key, value in [("schema_version", True), ("chromium_commit", "wrong"),
                           ("ardia_commit", "wrong"), ("source_sha256", {}),
                           ("result_sha256", {}), ("changed_paths", []),
                           ("patch_bytes", True), ("compiled", True), ("accepted", True),
                           ("integration_ready", True), ("unsupported", [])]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_metadata(dict(self.meta, **{key: value}), self.blobs)
        for name in self.blobs:
            altered = dict(self.blobs, **{name: self.blobs[name] + b"\n"})
            with self.subTest(patch=name), self.assertRaises(ValueError):
                validate_metadata(self.meta, altered)

    def test_sequential_pinned_application_and_static_adversaries(self):
        validate_metadata(self.meta, self.blobs)
        if CHROMIUM_SOURCE is None and ARDIA_SOURCE is None:
            self.skipTest("pinned source replay unavailable: explicit source roots not provided")
        if CHROMIUM_SOURCE is None or ARDIA_SOURCE is None:
            self.fail("both source roots are required for explicit replay")
        for repo, expected in ((CHROMIUM_SOURCE, CHROMIUM), (ARDIA_SOURCE, ARDIA)):
            actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
            self.assertEqual(expected, actual)
        for path, expected in INTERFACE_HASHES.items():
            data = subprocess.check_output(["git", "show", CHROMIUM + ":" + path], cwd=CHROMIUM_SOURCE)
            self.assertEqual(expected, digest(data), path)
        WORK.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="patch-guard-", dir=WORK) as tmp:
            target = Path(tmp)
            for path, expected in SOURCE_HASHES.items():
                if path.startswith("ardia/"):
                    repo, revision_path = ARDIA_SOURCE, ARDIA + ":engine/ardiacore/src/" + path
                else:
                    repo, revision_path = CHROMIUM_SOURCE, CHROMIUM + ":" + path
                data = subprocess.check_output(["git", "show", revision_path], cwd=repo)
                self.assertEqual(expected, digest(data), path)
                destination = target / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
            subprocess.run(["git", "init", "-q"], cwd=target, check=True, capture_output=True)
            for name in [*PREREQUISITES, "native-password-submission.patch"]:
                subprocess.run(["git", "apply", "--check", str(PATCH_DIR / name)], cwd=target,
                               check=True, capture_output=True)
                subprocess.run(["git", "apply", str(PATCH_DIR / name)], cwd=target,
                               check=True, capture_output=True)
            sources = {}
            for path, expected in RESULT_HASHES.items():
                data = (target / path).read_bytes()
                self.assertEqual(expected, digest(data), path)
                sources[path] = data.decode()
            validate_static(sources)
            mutations = [
                ("ardia/core/ac_native_password_broker.mm", "Event::XHR_SUCCEEDED"),
                ("ardia/core/ac_native_password_broker.mm", "offer->nonce != nonce"),
                ("ardia/core/ac_native_password_broker.mm", "save_account_subscription_ = lease->invalidations().Add("),
                ("components/password_manager/core/browser/password_manager.cc", "NativeSubmissionInferred(*manager)"),
                ("components/password_manager/core/browser/credential_manager_pending_prevent_silent_access_task.cc", "!delegate_->NativePasswordOnlyPolicy()"),
                ("ardia/core/ac_browser.mm", "callbacks->Notify();\n  return !!alive;"),
                ("chrome/browser/password_manager/chrome_password_manager_client.cc", "const auto clients = state->clients;"),
                ("chrome/browser/password_manager/chrome_password_manager_client.cc", "const auto profile_alive = profile->GetWeakPtr();"),
                ("chrome/browser/password_manager/chrome_password_manager_client.cc", "state->retired = true;"),
                ("chrome/browser/password_manager/chrome_password_manager_client.cc", "!state->transitioning &&"),
                ("chrome/browser/password_manager/chrome_password_manager_client.cc", "native_policy_state_ = native_policy;"),
                ("chrome/browser/password_manager/chrome_password_manager_client.h", "std::shared_ptr<void> native_policy_state_;"),
                ("ardia/core/ac_native_password_broker.mm", "client->NativeCaptureSessionAllowed()"),
            ]
            for path, marker in mutations:
                altered = dict(sources, **{path: sources[path].replace(marker, "REMOVED", 1)})
                with self.subTest(path=path, marker=marker), self.assertRaises(ValueError):
                    validate_static(altered)
            altered = dict(sources)
            path = "ardia/core/ac_native_password_broker.mm"
            altered[path] = altered[path].replace("  const auto event =", "  frame->GetWeakDocumentPtr();\n  const auto event =", 1)
            with self.assertRaisesRegex(ValueError, "post-navigation"):
                validate_static(altered)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--chromium-source", type=Path)
    parser.add_argument("--ardia-source", type=Path)
    args, remaining = parser.parse_known_args()
    if (args.chromium_source is None) != (args.ardia_source is None):
        parser.error("explicit replay requires both source roots")
    for source in (args.chromium_source, args.ardia_source):
        if source is not None and (not source.is_absolute() or not source.is_dir() or source.resolve() != source):
            parser.error("source roots must be existing canonical absolute directories")
    CHROMIUM_SOURCE = args.chromium_source
    ARDIA_SOURCE = args.ardia_source
    unittest.main(argv=[sys.argv[0], *remaining])
