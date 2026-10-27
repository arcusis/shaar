#!/usr/bin/env python3
"""Build isolated SDK8 or SDK9 packages from explicitly reviewed source pins."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import platform
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tomllib
import types
from pathlib import Path, PurePosixPath
from typing import NamedTuple

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'build/NativeBitwardenStrictSDK8'
PIN = ROOT / 'ThirdParty/BitwardenStrictEditSpike/sdk-package.pin.json'
class SourceProfile(NamedTuple):
    name: str
    work: Path
    pin: Path


SDK8_PROFILE = SourceProfile('sdk8', WORK, PIN)
SDK9_PROFILE = SourceProfile('sdk9', ROOT / 'build/NativeBitwardenStrictSDK9',
                            ROOT / 'ThirdParty/BitwardenStrictEditSpike/service-sdk-package.pin.json')
SDK8_PIN_SHA256 = '8c09ce296c3214848fb4728d16adfc2886c5bbecccd80760e389ab36948aba52'
SERVICE_PATCH_SHA256 = '8917fd3a357dd3a075391ba9d9aeefbf5343f8a665aebf58c4bdb457ca80d76c'
SERVICE_CANDIDATE_SHA256 = '9a202a82c43c72c116f2748683adb6c197be7c441ca41d83a5f31c906f20c50d'
SERVICE_PIN_SHA256 = 'a4c51b81da8a9521ce142401e030e0ac644c6fc505939529c66b4c8c97ac0f80'
SERVICE_REVIEW_SHA256 = 'dc75d775f7727996133e7034903b9f411237494f97953356722c7c3cc11799d8'
SERVICE_TREE = 'd43b3922107fb7e760090cb9ec18715c73776b2a'
SERVICE_MANIFEST = '88cd4a2b04071483b59f99f633b53b82ede90cc6c992b56cdde459c5903d2c67'
SERVICE_DIFF = '1f4a3ae897a64373299bdae1385de1ff40cc4196574631676ecf6bd268ecabc5'
SERVICE_PATCH_PATH = 'ThirdParty/BitwardenStrictEditSpike/strict-service-shapes.patch'

LEGACY_SHA256 = 'ca79ea5ebc76a11dbba612c57976d14c5ae9f04fdf099e495ec22e8b9547809e'
COMMIT = '5cf919837e83b71c2508bf99344ea57cf5f84e88'
TREE = '9af9432aefeed6796e40e5019ffdc8600f3381e9'
BASE_LOCK = '0496b9d35a9c6fd84f79bcc46aa774aa8a86f09eb8c64ba568bc18f4abd0c46a'
CANDIDATE_TREE = 'faa9b91b5013d5411a2519178609e92d6591948d'
CANDIDATE_LOCK = '48cef19482dfc18bbaf67e233b756a0b2a8e1551e558384893f0c05d3d7efd3e'
SOURCE_MANIFEST = '2e00c4a1e6e3d1fd6537e5f751daceca46a6e54ee67b96612d0cad7130108d38'
SOURCE_ENTRIES = 2784
FULL_DIFF = '4c12c68c8044dd72f4e53b2e86f06ad6da45b50c304faa9b7b77047cd21217d2'
SOURCE_REVIEW = 'd9737084c6550b41e7172dde1d4657230ee53ee53489dc47071bc740df6fd0ef'
WRITE_PATCH = 'e030b6a6eab842b11a1de1f293e75e09aa9bfca73330752296a266d2d1fc5b77'
WRITE_CANDIDATE = '0398b31e2640dc92bcb77ebb8840659831593c34da84f06f3a98d603130c923c'
CONSUMER = 'e96788e92dfbdfcf99676ec5e49b0ed112de29369baa29e4c671941d26e5479c'
REGISTRY = 'b9221d20249c212e69526c809727465c6079a7887be2f2bb1db722ae607db1a5'
REGISTRY_ENTRIES = 1703
GIT_CACHE = '2d74950b1b7d6ff4d34df3cefbb8c40e4a7da9204ab661fc963f86b0af1fb3fe'
GIT_CACHE_ENTRIES = 15
PATCHES = (
    ('ThirdParty/BitwardenAuthSpike/identity-mfa.patch', '850c53c73c710772b338bc88760543f66562119984e25bcf0337bfa986842a91'),
    ('ThirdParty/BitwardenKeyClearSpike/clear-crypto-keys.patch', 'f62fb617c615570d1a4280fd459af8b081caa758ad50fe4f57ebd7b34bdc2bf4'),
    ('ThirdParty/BitwardenSyncSpike/sync.patch', '26c6c57921ade94d4b6bed4b1627bf879ee6665fe23b5462b4b10a79633c7533'),
    ('ThirdParty/BitwardenSyncSpike/organization-keys.patch', 'b61303ecba50f6b1e75a083324e231878ae80d5663593302fede22dbd785cf1d'),
    ('ThirdParty/BitwardenSyncSpike/organization-key-replacement.patch', '4079044d3bd8dd3e8427ec86a1b2901704e4a08d2491dd67dbbf06dd2778294b'),
    ('ThirdParty/BitwardenRefreshSpike/refresh.patch', 'dbbade935ba424c56bbbe788ff87403c8404af1bd733a1e9a0175f34b836b6e8'),
    ('ThirdParty/BitwardenRefreshSpike/native-http-deadline.patch', '8ec29eb0694c0624788922950b878d05e324dc344fbcfb5d44f34f307b862b87'),
    ('ThirdParty/BitwardenStrictEditSpike/strict-personal-edit.patch', '559c0c0a3f3c2e0719d4543fc39e1f4f5998b145884e09255e6b36f38be93d66'),
)
PIN_KEYS = {'schema', 'accepted', 'integrationReady', 'sourceCommit', 'sourceGitTree',
            'sourceCargoLockSHA256', 'candidateGitTree', 'candidateCargoLockSHA256',
            'sourceManifestSHA256', 'sourceManifestEntries', 'fullDiffSHA256', 'changedPaths',
            'changedSourceSHA256', 'patches', 'writeCandidateSHA256', 'sourceReviewSHA256', 'licenseSHA256',
            'supportSHA256', 'dependencyChanges', 'cargoRegistrySHA256', 'cargoRegistryEntries',
            'cargoGitSHA256', 'cargoGitEntries',
            'consumerSHA256', 'consumerRequiredTokens', 'rustToolchain', 'target', 'architecture', 'minMacOS'}
LICENSES = {'DISCLAIMER.md': '24f8b14319ead83fb9cdbcc547db7abf8336c28a93e8dd5c4e13bf04b0f8692e',
            'LICENSE': '38e9e1a0452419fb8d2d8d023a79ff31f3106850f90d5ff381d45e65a0f992d9',
            'LICENSE_GPL.txt': 'b98fbb37db5b23bc5cfdcd16793206a5a7120a7b01f75374e5e0888376e4691c',
            'LICENSE_SDK.txt': 'db90f749155d7f8f354cff46a7395e5f4ae1012ba6a455aa2d3213ca9b00447d'}
SUPPORT_SHA256 = '157610fe70ca53028be7cebd4f74292e4c64d28caf67b12ebf17d11013bed9ae'
CONSUMER_APIS = ('strictPreparePersonalLogin', 'strictPersonalUpdate',
                 'StrictPersonalPreparation', 'StrictPersonalWriteOutcome')
HEX64 = re.compile(r'^[0-9a-f]{64}$')
HEX40 = re.compile(r'^[0-9a-f]{40}$')
SANDBOX = '/usr/bin/sandbox-exec'
NO_NETWORK = '(version 1)(allow default)(deny network*)'
HOSTED_PIN_SHA256 = 'c7f71d14a29abfa5a4dca441c49fce5e6a87127d4fff8a206af793b9558b3489'


def load_hosted_preparer(path: Path, checkpoint: Path, checkpoint_sha: str):
    require_regular(path)
    require_regular(checkpoint)
    if not HEX64.fullmatch(checkpoint_sha) or digest(checkpoint) != checkpoint_sha:
        raise ValueError('hosted checkpoint digest mismatch')
    record = json_bytes(checkpoint.read_bytes())
    expected_names = {'scripts/build-native-bitwarden-strict-sdk.py',
                      'scripts/prepare-native-bitwarden-hosted-inputs.py',
                      'ThirdParty/BitwardenStrictEditSpike/hosted-inputs.pin.json'}
    if (not isinstance(record, dict) or set(record) != {'schema', 'files'} or
        type(record['schema']) is not int or record['schema'] != 1 or
        not isinstance(record['files'], dict) or set(record['files']) != expected_names):
        raise ValueError('hosted checkpoint schema')
    paths = {'scripts/build-native-bitwarden-strict-sdk.py': Path(__file__).absolute(),
             'scripts/prepare-native-bitwarden-hosted-inputs.py': path,
             'ThirdParty/BitwardenStrictEditSpike/hosted-inputs.pin.json': ROOT / 'ThirdParty/BitwardenStrictEditSpike/hosted-inputs.pin.json'}
    for name, item in paths.items():
        if digest(item) != record['files'][name]:
            raise ValueError('hosted checkpoint source drift')
    if record['files']['ThirdParty/BitwardenStrictEditSpike/hosted-inputs.pin.json'] != HOSTED_PIN_SHA256:
        raise ValueError('hosted pin mismatch')
    source = path.read_bytes()
    if sha(source) != record['files']['scripts/prepare-native-bitwarden-hosted-inputs.py']:
        raise ValueError('hosted preparer changed')
    module = types.ModuleType('hosted_sdk9_inputs')
    module.__file__ = str(path)
    exec(compile(source, str(path), 'exec'), module.__dict__)
    return module, paths


def hosted_input_profile(profile: SourceProfile, historical: tuple, hosted_values: tuple) -> bool:
    selected = any(value is not None for value in hosted_values)
    if selected:
        if (profile != SDK9_PROFILE or any(value is None for value in hosted_values) or
            any(value is not None for value in historical)):
            raise ValueError('hosted and historical input profiles cannot be mixed')
    elif any(value is None for value in historical):
        raise ValueError('historical profile requires both Cargo caches')
    return selected


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def digest(path: Path) -> str:
    return sha(path.read_bytes())


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate JSON key')
        result[key] = value
    return result


def json_bytes(data: bytes):
    return json.loads(data, object_pairs_hook=unique_object)


def safe_relative(name: str) -> str:
    if not isinstance(name, str) or not name or '\\' in name or any(ord(c) < 32 or ord(c) == 127 for c in name):
        raise ValueError('invalid path')
    path = PurePosixPath(name)
    if path.is_absolute() or any(part in ('', '.', '..') for part in name.split('/')) or str(path) != name:
        raise ValueError('noncanonical relative path')
    return name


def require_regular(path: Path) -> None:
    if not path.is_absolute() or path.resolve(strict=True) != path:
        raise ValueError('path must be absolute and canonical')
    for item in (path, *path.parents):
        mode = item.lstat().st_mode
        if stat.S_ISLNK(mode):
            raise ValueError('symlink path')
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError('file is not regular')


def require_directory(path: Path) -> None:
    if not path.is_absolute() or path.resolve(strict=True) != path:
        raise ValueError('directory must be absolute and canonical')
    for item in (path, *path.parents):
        if stat.S_ISLNK(item.lstat().st_mode):
            raise ValueError('symlink directory')
    if not stat.S_ISDIR(path.lstat().st_mode):
        raise ValueError('directory missing')


def under(root: Path, name: str) -> Path:
    safe_relative(name)
    result = root.joinpath(*PurePosixPath(name).parts)
    if not result.is_relative_to(root):
        raise ValueError('path escapes root')
    return result


def file_inventory(root: Path, *, exclude_git: bool = False, allow_git_dirs: bool = False) -> tuple[dict[str, str], str, int]:
    require_directory(root)
    files = {}
    rows = []
    for current, dirs, names in os.walk(root, topdown=True, followlinks=False):
        here = Path(current)
        if exclude_git and here == root and '.git' in dirs:
            dirs.remove('.git')
        elif '.git' in dirs and not allow_git_dirs:
            raise ValueError('unexpected nested git directory')
        for name in sorted(dirs + names):
            item = here / name
            rel = item.relative_to(root).as_posix()
            safe_relative(rel)
            mode = item.lstat().st_mode
            if stat.S_ISREG(mode):
                value = digest(item)
                files[rel] = value
                rows.append({'path': rel, 'kind': 'file', 'executable': bool(mode & 0o111), 'sha256': value})
            elif stat.S_ISDIR(mode):
                rows.append({'path': rel, 'kind': 'directory'})
            else:
                raise ValueError('symlink or special file')
    rows.sort(key=lambda x: x['path'])
    packed = ''.join(json.dumps(row, sort_keys=True, separators=(',', ':')) + '\n' for row in rows).encode()
    return files, sha(packed), len(rows)


def validate_package_inventory(root: Path, expected: set[str]) -> dict[str, str]:
    files, _, _ = file_inventory(root)
    if set(files) != expected:
        raise ValueError('package file inventory mismatch')
    actual_dirs = set()
    for current, dirs, _ in os.walk(root, topdown=True, followlinks=False):
        for name in dirs:
            actual_dirs.add((Path(current) / name).relative_to(root).as_posix())
    expected_dirs = {parent.as_posix() for name in expected for parent in PurePosixPath(name).parents
                     if parent.as_posix() != '.'}
    if actual_dirs != expected_dirs:
        raise ValueError('package directory inventory mismatch')
    return files


def validate_pin(pin: dict) -> None:
    if not isinstance(pin, dict) or set(pin) != PIN_KEYS or type(pin['schema']) is not int or pin['schema'] != 1:
        raise ValueError('invalid pin schema')
    fixed = {'accepted': False, 'integrationReady': False, 'sourceCommit': COMMIT,
             'sourceGitTree': TREE, 'sourceCargoLockSHA256': BASE_LOCK, 'rustToolchain': '1.98.0',
             'target': 'aarch64-apple-darwin', 'architecture': 'arm64', 'minMacOS': '26.0',
             'candidateGitTree': CANDIDATE_TREE, 'candidateCargoLockSHA256': CANDIDATE_LOCK,
             'sourceManifestSHA256': SOURCE_MANIFEST, 'sourceManifestEntries': SOURCE_ENTRIES,
             'fullDiffSHA256': FULL_DIFF, 'sourceReviewSHA256': SOURCE_REVIEW,
             'writeCandidateSHA256': WRITE_CANDIDATE, 'consumerSHA256': CONSUMER,
             'cargoRegistrySHA256': REGISTRY, 'cargoRegistryEntries': REGISTRY_ENTRIES,
             'cargoGitSHA256': GIT_CACHE, 'cargoGitEntries': GIT_CACHE_ENTRIES}
    for key, expected in fixed.items():
        if type(pin[key]) is not type(expected) or pin[key] != expected:
            raise ValueError('pin fixed field mismatch: ' + key)
    for key in ('candidateCargoLockSHA256', 'sourceManifestSHA256', 'fullDiffSHA256',
                'writeCandidateSHA256', 'supportSHA256', 'cargoRegistrySHA256', 'cargoGitSHA256', 'consumerSHA256'):
        if not isinstance(pin[key], str) or not HEX64.fullmatch(pin[key]):
            raise ValueError('invalid digest: ' + key)
    if not isinstance(pin['candidateGitTree'], str) or not HEX40.fullmatch(pin['candidateGitTree']):
        raise ValueError('invalid candidate tree')
    for key in ('sourceManifestEntries', 'cargoRegistryEntries', 'cargoGitEntries'):
        if type(pin[key]) is not int or pin[key] <= 0:
            raise ValueError('invalid entry count')
    patches = pin['patches']
    if not isinstance(patches, list) or len(patches) != 9:
        raise ValueError('nine patches required')
    for index, item in enumerate(patches):
        if not isinstance(item, dict) or set(item) != {'path', 'sha256'}:
            raise ValueError('invalid patch entry')
        safe_relative(item['path'])
        if not isinstance(item['sha256'], str) or not HEX64.fullmatch(item['sha256']):
            raise ValueError('invalid patch digest')
        if index < 8 and (item['path'], item['sha256']) != PATCHES[index]:
            raise ValueError('prerequisite patch changed or reordered')
    if (patches[8]['path'] != 'ThirdParty/BitwardenStrictEditSpike/strict-personal-write.patch' or
            patches[8]['sha256'] != WRITE_PATCH or len({p['path'] for p in patches}) != 9):
        raise ValueError('unsafe write patch path')
    changed = pin['changedPaths']
    if (not isinstance(changed, list) or not changed or
            any(not isinstance(p, str) or safe_relative(p) != p for p in changed) or
            changed != sorted(set(changed))):
        raise ValueError('invalid changed-path inventory')
    digests = pin['changedSourceSHA256']
    if not isinstance(digests, dict) or set(digests) != set(changed):
        raise ValueError('changed-source inventory mismatch')
    if any(not isinstance(v, str) or not HEX64.fullmatch(v) for v in digests.values()):
        raise ValueError('invalid changed-source hash')
    licenses = pin['licenseSHA256']
    if licenses != LICENSES or pin['supportSHA256'] != SUPPORT_SHA256:
        raise ValueError('license inventory mismatch')
    if not isinstance(pin['dependencyChanges'], list):
        raise ValueError('dependency change inventory invalid')
    for change in pin['dependencyChanges']:
        if (not isinstance(change, dict) or set(change) != {'name', 'version', 'before', 'after'} or
                not all(isinstance(change[k], str) and change[k] for k in ('name', 'version')) or
                any(not isinstance(change[k], list) or any(not isinstance(x, str) for x in change[k]) for k in ('before', 'after'))):
            raise ValueError('invalid dependency delta')
    identities = [(x['name'], x['version']) for x in pin['dependencyChanges']]
    if len(identities) != len(set(identities)):
        raise ValueError('duplicate dependency delta')
    tokens = pin['consumerRequiredTokens']
    if (not isinstance(tokens, list) or len(tokens) < 2 or len(set(tokens)) != len(tokens) or
            any(not isinstance(t, str) or not t or '\n' in t for t in tokens)):
        raise ValueError('invalid consumer API inventory')


def load_pin(path: Path, expected: str) -> dict:
    if not isinstance(expected, str) or not HEX64.fullmatch(expected):
        raise ValueError('explicit reviewed pin SHA-256 required')
    require_regular(path)
    data = path.read_bytes()
    if sha(data) != expected:
        raise ValueError('pin digest mismatch')
    pin = json_bytes(data)
    validate_pin(pin)
    return pin


def validate_service_pin(pin: dict, base: dict, candidate: dict) -> dict:
    """Validate SDK9 against independently validated SDK8 and service candidate."""
    validate_pin(base)
    if (not isinstance(candidate, dict) or type(candidate.get('schema')) is not int or
            candidate['schema'] != 1 or candidate.get('integrationReady') is not False or
            candidate.get('candidateStatus') != 'SOURCE_CANDIDATE_REVIEW_REQUIRED' or
            candidate.get('sourceCommit') != COMMIT or candidate.get('baseTree') != CANDIDATE_TREE or
            candidate.get('baselinePatches') != base['patches'] or
            candidate.get('patchSha256') != SERVICE_PATCH_SHA256):
        raise ValueError('service candidate ancestry mismatch')
    transition = candidate.get('changedSourceSha256')
    paths = candidate.get('changedPaths')
    if (not isinstance(transition, dict) or not isinstance(paths, list) or
            any(not isinstance(name, str) for name in paths) or paths != sorted(set(paths)) or
            set(transition) != set(paths) or len(transition) != 3 or
            not set(transition).issubset(base['changedSourceSHA256'])):
        raise ValueError('service transition inventory mismatch')
    for name, value in transition.items():
        safe_relative(name)
        if not isinstance(value, str) or not HEX64.fullmatch(value):
            raise ValueError('service transition digest invalid')
    primary = candidate.get('primarySha256')
    if (not isinstance(primary, dict) or len(primary) != 15 or
            not isinstance(candidate.get('primaryPaths'), dict) or
            not isinstance(candidate.get('primaryCommits'), dict) or
            set(primary) != set(candidate['primaryPaths'])):
        raise ValueError('primary source inventory mismatch')
    for name, value in primary.items():
        safe_relative(name)
        safe_relative(candidate['primaryPaths'][name])
        if not isinstance(value, str) or not HEX64.fullmatch(value):
            raise ValueError('primary source digest invalid')
    changes = dict(base['changedSourceSHA256'])
    changes.update(transition)
    expected = {'schema': 1, 'profile': 'sdk9-service-shapes', 'accepted': False,
        'integrationReady': False, 'sdk8PinSHA256': SDK8_PIN_SHA256,
        'baseTree': CANDIDATE_TREE, 'baseSourceManifestSHA256': SOURCE_MANIFEST,
        'baseSourceManifestEntries': SOURCE_ENTRIES, 'sourceCommit': COMMIT,
        'candidateGitTree': SERVICE_TREE, 'candidateCargoLockSHA256': CANDIDATE_LOCK,
        'sourceManifestSHA256': SERVICE_MANIFEST, 'sourceManifestEntries': SOURCE_ENTRIES,
        'fullDiffSHA256': SERVICE_DIFF, 'changedPaths': sorted(changes),
        'changedSourceSHA256': changes, 'patches': base['patches'] + [
            {'path': SERVICE_PATCH_PATH, 'sha256': SERVICE_PATCH_SHA256}],
        'serviceCandidateSHA256': SERVICE_CANDIDATE_SHA256,
        'primarySha256': primary, 'primaryPaths': candidate['primaryPaths'],
        'primaryCommits': candidate['primaryCommits'], 'dependencyChanges': base['dependencyChanges'],
        'serviceReviewSHA256': SERVICE_REVIEW_SHA256}
    if (not isinstance(pin, dict) or set(pin) != set(expected) or
            any(type(pin[k]) is not type(v) or pin[k] != v for k, v in expected.items())):
        raise ValueError('SDK9 pin mismatch')
    effective = dict(base)
    for key in ('candidateGitTree', 'candidateCargoLockSHA256', 'sourceManifestSHA256',
                'sourceManifestEntries', 'fullDiffSHA256', 'changedPaths',
                'changedSourceSHA256', 'patches', 'dependencyChanges'):
        effective[key] = pin[key]
    return effective


def validate_service_review(review: dict, pin: dict) -> None:
    expected = {key: value for key, value in pin.items() if key != 'serviceReviewSHA256'}
    if (not isinstance(review, dict) or set(review) != set(expected) or
            any(type(review[k]) is not type(value) or review[k] != value for k, value in expected.items())):
        raise ValueError('service review differs from pin')


def verify_primary_sources(root: Path, candidate: dict) -> None:
    files, _, _ = file_inventory(root)
    if files != candidate['primarySha256']:
        raise ValueError('primary sources differ from reviewed candidate')


def verify_service_transition(helper, sdk: Path, pin: dict, candidate: dict, env: dict[str, str]) -> None:
    git = lambda *args: run(helper, ['git', '-C', str(sdk), *args], ROOT, env, 120)
    paths = git('diff', '--no-ext-diff', '--no-textconv', '--name-only', CANDIDATE_TREE,
                pin['candidateGitTree']).splitlines()
    if paths != candidate['changedPaths']:
        raise ValueError('SDK9 transition path mismatch')
    if sha(git('show', CANDIDATE_TREE + ':Cargo.lock').encode()) != pin['candidateCargoLockSHA256']:
        raise ValueError('SDK8 lock changed in transition')


def validate_source_review(review: dict, pin: dict) -> None:
    fields = ('sourceCommit', 'sourceGitTree', 'candidateGitTree', 'sourceManifestSHA256',
              'sourceManifestEntries', 'fullDiffSHA256', 'changedPaths', 'changedSourceSHA256',
              'candidateCargoLockSHA256', 'dependencyChanges', 'writeCandidateSHA256', 'patches')
    if not isinstance(review, dict) or set(review) != set(fields):
        raise ValueError('source review schema mismatch')
    if any(type(review[key]) is not type(pin[key]) or review[key] != pin[key] for key in fields):
        raise ValueError('source review differs from pin')


def validate_checkpoint(candidate: dict, pin: dict) -> None:
    if (not isinstance(candidate, dict) or type(candidate.get('schema')) is not int or
            candidate['schema'] != 1 or candidate.get('sourceCommit') != COMMIT or
            candidate.get('integrationReady') is not False or
            candidate.get('preparationPatchSha256') != PATCHES[7][1] or
            candidate.get('writePatchSha256') != pin['patches'][8]['sha256']):
        raise ValueError('write checkpoint mismatch')
    changed = candidate.get('writeSourceSha256')
    if not isinstance(changed, dict) or not changed:
        raise ValueError('write checkpoint source inventory missing')
    for name, value in changed.items():
        safe_relative(name)
        if pin['changedSourceSHA256'].get(name) != value:
            raise ValueError('write checkpoint source mismatch')


def validate_dependencies(base: bytes, candidate: bytes, allowed: list[dict]) -> None:
    def packages(data):
        parsed = tomllib.loads(data.decode())
        result = {}
        for package in parsed.get('package', []):
            key = (package.get('name'), package.get('version'), package.get('source'))
            if key in result or not all(isinstance(x, str) and x for x in key[:2]):
                raise ValueError('duplicate or malformed lock package')
            result[key] = package
        return result
    before, after = packages(base), packages(candidate)
    if set(before) != set(after):
        raise ValueError('dependency package inventory changed')
    delta = {(x['name'], x['version']): x for x in allowed}
    seen = set()
    for key in before:
        old, new = before[key], after[key]
        if old == new:
            continue
        if key[2] is not None or (key[0], key[1]) not in delta:
            raise ValueError('unapproved dependency metadata change')
        expected = delta[(key[0], key[1])]
        if ({k: v for k, v in old.items() if k != 'dependencies'} !=
                {k: v for k, v in new.items() if k != 'dependencies'} or
                old.get('dependencies', []) != expected['before'] or
                new.get('dependencies', []) != expected['after']):
            raise ValueError('dependency delta mismatch')
        seen.add((key[0], key[1]))
    if seen != set(delta):
        raise ValueError('unused dependency delta')


def validate_consumer(data: bytes, pin: dict) -> None:
    if sha(data) != pin['consumerSHA256']:
        raise ValueError('consumer digest mismatch')
    text = data.decode('utf-8')
    if 'import Foundation' not in text or 'import ArcusisBitwardenSDK' not in text:
        raise ValueError('consumer imports missing')
    if any(token not in text for token in (*CONSUMER_APIS, *pin['consumerRequiredTokens'])):
        raise ValueError('consumer strict API references missing')


def load_packaging_helpers(path: Path):
    require_regular(path)
    if digest(path) != LEGACY_SHA256:
        raise ValueError('reviewed packaging helper changed')
    spec = importlib.util.spec_from_file_location('strict_sdk_legacy_helpers', path)
    if spec is None or spec.loader is None:
        raise ValueError('packaging helper unavailable')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(helper, argv: list[str], cwd: Path, environment: dict[str, str], timeout: int = 3600) -> str:
    # Sandbox denies all networking to Cargo build scripts, Swift and bindgen.
    return helper.command([SANDBOX, '-p', NO_NETWORK, *argv], cwd, environment,
                          timeout=timeout, cleanup_success=True)


def generated_files(path: Path) -> dict[str, str]:
    result, _, _ = file_inventory(path)
    if not result or any('/' in name for name in result):
        raise ValueError('generated binding inventory invalid')
    if not all(name.endswith(('.swift', '.h', '.modulemap')) for name in result):
        raise ValueError('unexpected generated binding')
    if not all(any(name.endswith(ext) for name in result) for ext in ('.swift', '.h', '.modulemap')):
        raise ValueError('missing generated binding family')
    for name in result:
        if name.endswith('.modulemap'):
            text = (path / name).read_text()
            headers = re.findall(r'\bheader\s+"([^\"]+)"', text)
            if not headers or any(safe_relative(h) != h or h not in result or not h.endswith('.h') for h in headers):
                raise ValueError('generated modulemap header mismatch')
    return result


def verify_source(helper, sdk: Path, pin: dict, env: dict[str, str]) -> None:
    files, fingerprint, count = file_inventory(sdk, exclude_git=True)
    if (fingerprint, count) != (pin['sourceManifestSHA256'], pin['sourceManifestEntries']):
        raise ValueError('complete source inventory mismatch')
    if any(files.get(path) != expected for path, expected in pin['changedSourceSHA256'].items()):
        raise ValueError('changed source hash mismatch')
    git = lambda *args: run(helper, ['git', '-C', str(sdk), *args], ROOT, env, 120)
    if git('rev-parse', 'HEAD').strip() != COMMIT:
        raise ValueError('upstream commit mismatch')
    if git('write-tree').strip() != pin['candidateGitTree']:
        raise ValueError('candidate tree mismatch')
    if git('rev-parse', COMMIT + '^{tree}').strip() != TREE:
        raise ValueError('upstream tree mismatch')
    diff = git('diff', '--no-ext-diff', '--no-textconv', '--binary', COMMIT, pin['candidateGitTree']).encode()
    if sha(diff) != pin['fullDiffSHA256'] or git('diff', '--no-ext-diff', '--no-textconv', '--name-only', COMMIT, pin['candidateGitTree']).splitlines() != pin['changedPaths']:
        raise ValueError('source diff mismatch')
    git('diff', '--quiet')
    if git('ls-files', '--others').strip():
        raise ValueError('untracked source file')
    lock = (sdk / 'Cargo.lock').read_bytes()
    original = git('show', COMMIT + ':Cargo.lock').encode()
    if sha(original) != BASE_LOCK or sha(lock) != pin['candidateCargoLockSHA256']:
        raise ValueError('Cargo.lock mismatch')
    validate_dependencies(original, lock, pin['dependencyChanges'])
    for name, expected in pin['licenseSHA256'].items():
        if files.get(name) != expected:
            raise ValueError('license source mismatch')
    support = 'crates/bitwarden-uniffi/swift/Sources/BitwardenSdkSupport/NaiveDateFormatter.swift'
    if files.get(support) != pin['supportSHA256']:
        raise ValueError('support source mismatch')
    client = (sdk / 'crates/bitwarden-api-base/src/client.rs').read_text()
    if not re.search(r'#\[cfg\(not\(debug_assertions\)\)\]\s*\{\s*'
                     r'client_builder\s*=\s*client_builder\.https_only\(true\);', client):
        raise ValueError('release HTTPS-only source guard missing')
    profiles = tomllib.loads((sdk / 'Cargo.toml').read_text()).get('profile', {})
    for name, wanted in (('release', False), ('dev', True)):
        profile = profiles.get(name, {})
        if profile.get('debug-assertions', wanted) is not wanted:
            raise ValueError('Cargo profile debug assertion mismatch')
        if any('debug-assertions' in value for value in profile.get('package', {}).values()):
            raise ValueError('package debug assertion overrides unsupported')


def stage_package(helper, sdk: Path, generated: Path, dylib: Path, pkg: Path,
                  pin: dict, mode: str, binding: dict[str, str], profile: SourceProfile = SDK8_PROFILE,
                  hosted_provenance: dict | None = None) -> dict:
    maps = helper.stage_generated_sources(sdk, generated, pkg)
    ffi = pkg / 'Sources/BitwardenFFI/include'
    notices = pkg / 'ThirdPartyNotices'
    notices.mkdir()
    for name in pin['licenseSHA256']:
        shutil.copy2(sdk / name, notices / name)
    framework = pkg / 'Frameworks/BitwardenSDK.xcframework'
    library = framework / 'macos-arm64'
    (library / 'Headers').mkdir(parents=True)
    shutil.copy2(dylib, library / 'libbitwarden_uniffi.dylib')
    for path in helper.safe_tree(ffi):
        shutil.copy2(path, library / 'Headers' / path.name)
    info = {'AvailableLibraries': [{'LibraryIdentifier': 'macos-arm64',
              'LibraryPath': 'libbitwarden_uniffi.dylib', 'HeadersPath': 'Headers',
              'SupportedArchitectures': ['arm64'], 'SupportedPlatform': 'macos'}],
            'CFBundlePackageType': 'XFWK', 'XCFrameworkFormatVersion': '1.0'}
    (framework / 'Info.plist').write_bytes(plistlib.dumps(info, sort_keys=True))
    (pkg / 'Package.swift').write_text(helper.SDK_PACKAGE_SWIFT)
    swift = {n: h for n, h in binding.items() if n.endswith('.swift')}
    headers = {n: h for n, h in binding.items() if n.endswith('.h')}
    expected = {'Package.swift', 'Sources/BitwardenFFI/shim.c',
                'Sources/BitwardenFFI/include/module.modulemap',
                'Sources/BitwardenSdkSupport/NaiveDateFormatter.swift',
                'Frameworks/BitwardenSDK.xcframework/Info.plist',
                'Frameworks/BitwardenSDK.xcframework/macos-arm64/libbitwarden_uniffi.dylib',
                'Frameworks/BitwardenSDK.xcframework/macos-arm64/Headers/module.modulemap'}
    expected |= {'Sources/ArcusisBitwardenSDK/' + name for name in swift}
    expected |= {'Sources/BitwardenFFI/include/' + name for name in headers}
    expected |= {'Frameworks/BitwardenSDK.xcframework/macos-arm64/Headers/' + name for name in headers}
    expected |= {'ThirdPartyNotices/' + name for name in pin['licenseSHA256']}
    files = validate_package_inventory(pkg, expected)
    for name, value in swift.items():
        if files['Sources/ArcusisBitwardenSDK/' + name] != value:
            raise ValueError('generated Swift mismatch')
    for name, value in headers.items():
        if (files['Sources/BitwardenFFI/include/' + name] != value or
                files['Frameworks/BitwardenSDK.xcframework/macos-arm64/Headers/' + name] != value):
            raise ValueError('generated header mismatch')
    if files['Sources/BitwardenSdkSupport/NaiveDateFormatter.swift'] != pin['supportSHA256']:
        raise ValueError('package support mismatch')
    if any(files['ThirdPartyNotices/' + name] != value for name, value in pin['licenseSHA256'].items()):
        raise ValueError('package license mismatch')
    modulemap = 'Sources/BitwardenFFI/include/module.modulemap'
    if files[modulemap] != files['Frameworks/BitwardenSDK.xcframework/macos-arm64/Headers/module.modulemap']:
        raise ValueError('framework modulemap mismatch')
    modules = sorted(set(x for path in maps for x in re.findall(r'\bmodule\s+([A-Za-z_][A-Za-z0-9_]*)', path.read_text())))
    if not modules:
        raise ValueError('module inventory empty')
    manifest = {'schema': 1, 'accepted': False, 'integrationReady': False,
                'sourceCommit': COMMIT, 'candidateGitTree': pin['candidateGitTree'],
                'sourceManifestSHA256': pin['sourceManifestSHA256'], 'writeCandidateSHA256': pin['writeCandidateSHA256'],
                'testOnly': mode == 'debug', 'mode': mode, 'architecture': 'arm64', 'minMacOS': '26.0',
                'dylibSHA256': digest(dylib), 'generatedSHA256': binding, 'generatedModules': modules,
                'licenseSHA256': pin['licenseSHA256'], 'fileSHA256': files}
    if profile == SDK9_PROFILE:
        manifest.update(profile='sdk9-service-shapes', serviceCandidateSHA256=SERVICE_CANDIDATE_SHA256,
                        servicePatchSHA256=SERVICE_PATCH_SHA256)
    if hosted_provenance is not None:
        manifest['hostedInputProvenance'] = hosted_provenance
    (pkg / 'build-manifest.json').write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
    actual = validate_package_inventory(pkg, expected | {'build-manifest.json'})
    if any(actual[k] != v for k, v in files.items()):
        raise ValueError('package final inventory mismatch')
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile', choices=('sdk8', 'sdk9'), default='sdk8')
    parser.add_argument('--pin-sha256', required=True)
    parser.add_argument('--service-patch', type=Path)
    parser.add_argument('--service-candidate', type=Path)
    parser.add_argument('--service-source-review', type=Path)
    parser.add_argument('--service-primary', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--legacy-builder', type=Path, required=True)
    parser.add_argument('--upstream', type=Path, required=True)
    parser.add_argument('--patch-root', type=Path, required=True)
    parser.add_argument('--write-candidate', type=Path, required=True)
    parser.add_argument('--source-review', type=Path, required=True)
    parser.add_argument('--cargo-registry', type=Path)
    parser.add_argument('--cargo-git', type=Path)
    parser.add_argument('--hosted-inputs', type=Path)
    parser.add_argument('--hosted-preparer', type=Path)
    parser.add_argument('--hosted-checkpoint', type=Path)
    parser.add_argument('--hosted-checkpoint-sha256')
    parser.add_argument('--hosted-rustup-home', type=Path)
    parser.add_argument('--hosted-cargo', type=Path)
    parser.add_argument('--consumer-source', type=Path, required=True)
    args = parser.parse_args()
    profile = SDK8_PROFILE if args.profile == 'sdk8' else SDK9_PROFILE
    hosted_args = (args.hosted_inputs, args.hosted_preparer, args.hosted_checkpoint,
                   args.hosted_checkpoint_sha256, args.hosted_rustup_home, args.hosted_cargo)
    hosted = hosted_input_profile(profile, (args.cargo_registry, args.cargo_git), hosted_args)
    if hosted:
        hosted_module, hosted_paths = load_hosted_preparer(
            args.hosted_preparer, args.hosted_checkpoint, args.hosted_checkpoint_sha256)
        require_directory(args.hosted_inputs)
        require_directory(args.hosted_rustup_home)
        require_regular(args.hosted_cargo)
    service_args = (args.service_patch, args.service_candidate, args.service_source_review, args.service_primary)
    if profile == SDK8_PROFILE:
        if any(value is not None for value in service_args):
            raise ValueError('SDK8 does not accept service profile inputs')
        base_pin = load_pin(profile.pin, args.pin_sha256)
        pin = base_pin
        service_candidate = None
        service_pin = None
    else:
        if any(value is None for value in service_args):
            raise ValueError('SDK9 requires all service profile inputs')
        base_path = under(args.patch_root, 'ThirdParty/BitwardenStrictEditSpike/sdk-package.pin.json')
        base_pin = load_pin(base_path, SDK8_PIN_SHA256)
        for path in (profile.pin, args.service_patch, args.service_candidate, args.service_source_review):
            require_regular(path)
        require_directory(args.service_primary)
        if (args.pin_sha256 != SERVICE_PIN_SHA256 or digest(profile.pin) != SERVICE_PIN_SHA256 or
                digest(args.service_patch) != SERVICE_PATCH_SHA256 or
                digest(args.service_candidate) != SERVICE_CANDIDATE_SHA256 or
                digest(args.service_source_review) != SERVICE_REVIEW_SHA256):
            raise ValueError('SDK9 reviewed input digest mismatch')
        service_pin = json_bytes(profile.pin.read_bytes())
        service_candidate = json_bytes(args.service_candidate.read_bytes())
        pin = validate_service_pin(service_pin, base_pin, service_candidate)
        validate_service_review(json_bytes(args.service_source_review.read_bytes()), service_pin)
        verify_primary_sources(args.service_primary, service_candidate)
    for path in (args.upstream, args.patch_root):
        require_directory(path)
    if not hosted:
        require_directory(args.cargo_registry)
        require_directory(args.cargo_git)
    for path in (args.write_candidate, args.source_review, args.consumer_source, args.legacy_builder):
        require_regular(path)
    if digest(args.source_review) != SOURCE_REVIEW:
        raise ValueError('source review digest mismatch')
    validate_source_review(json_bytes(args.source_review.read_bytes()), base_pin)
    if digest(args.write_candidate) != pin['writeCandidateSHA256']:
        raise ValueError('write checkpoint digest mismatch')
    validate_checkpoint(json_bytes(args.write_candidate.read_bytes()), base_pin)
    consumer = args.consumer_source.read_bytes()
    validate_consumer(consumer, pin)
    if profile == SDK9_PROFILE and b'revisionToken' not in consumer:
        raise ValueError('consumer revision token API reference missing')
    for entry in base_pin['patches']:
        path = under(args.patch_root, entry['path'])
        require_regular(path)
        if digest(path) != entry['sha256']:
            raise ValueError('patch digest mismatch')
    if not hosted:
        _, registry_hash, registry_count = file_inventory(args.cargo_registry)
        if (registry_hash, registry_count) != (pin['cargoRegistrySHA256'], pin['cargoRegistryEntries']):
            raise ValueError('offline registry inventory mismatch')
        _, git_hash, git_count = file_inventory(args.cargo_git, allow_git_dirs=True)
        if (git_hash, git_count) != (pin['cargoGitSHA256'], pin['cargoGitEntries']):
            raise ValueError('offline git cache inventory mismatch')
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise ValueError('requires arm64 macOS')
    require_directory(profile.work)
    out = args.output
    if (not out.is_absolute() or out.parent != profile.work or safe_relative(out.name) != out.name or
            out.exists() or out.is_symlink()):
        raise ValueError('owned output must be a fresh direct child')
    helper = load_packaging_helpers(args.legacy_builder)
    env = {name: os.environ[name] for name in ('PATH', 'HOME', 'TMPDIR') if name in os.environ}
    if hosted:
        out.mkdir(mode=0o700)
        hosted_home = out / 'hosted-home'
        hosted_home.mkdir(mode=0o700)
        env.update(HOME=str(hosted_home), RUSTUP_HOME=str(args.hosted_rustup_home),
                   PATH=str(args.hosted_cargo.parent) + ':/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin')
        rust_cmd = [str(args.hosted_cargo.parent / 'rustc'), '-vV']
    else:
        rust_cmd = ['rustc', '+1.98.0', '-vV']
    rust = run(helper, rust_cmd, ROOT, env, 30)
    if not rust.startswith('rustc 1.98.0 (88d9e12ae 2026-08-18)\n') or 'host: aarch64-apple-darwin\n' not in rust:
        raise ValueError('Rust toolchain identity mismatch')
    if not hosted:
        out.mkdir(mode=0o700)
    helper.LOG_DIR = out / 'logs'
    (out / 'toolchain.txt').write_text(rust)
    sdk = out / 'source'
    run(helper, ['git', 'clone', '--local', '--no-hardlinks', '--no-checkout', str(args.upstream), str(sdk)], ROOT, env, 180)
    run(helper, ['git', '-C', str(sdk), 'checkout', '--detach', COMMIT], ROOT, env, 120)
    for entry in base_pin['patches']:
        path = under(args.patch_root, entry['path'])
        if digest(path) != entry['sha256']:
            raise ValueError('patch changed before application')
        run(helper, ['git', '-C', str(sdk), 'apply', '--check', '--whitespace=error', str(path)], ROOT, env, 120)
        run(helper, ['git', '-C', str(sdk), 'apply', '--whitespace=error', str(path)], ROOT, env, 120)
    run(helper, ['git', '-C', str(sdk), 'add', '-A', '-f'], ROOT, env, 120)
    verify_source(helper, sdk, base_pin, env)
    if profile == SDK9_PROFILE:
        if digest(args.service_patch) != SERVICE_PATCH_SHA256:
            raise ValueError('service patch changed before application')
        run(helper, ['git', '-C', str(sdk), 'apply', '--check', '--whitespace=error', str(args.service_patch)], ROOT, env, 120)
        run(helper, ['git', '-C', str(sdk), 'apply', '--whitespace=error', str(args.service_patch)], ROOT, env, 120)
        run(helper, ['git', '-C', str(sdk), 'add', '-A', '-f'], ROOT, env, 120)
        verify_source(helper, sdk, pin, env)
        verify_service_transition(helper, sdk, pin, service_candidate, env)
    cargo_home = out / 'cargo-home'
    cargo_home.mkdir()
    hosted_provenance = None
    if hosted:
        hosted_pin = ROOT / 'ThirdParty/BitwardenStrictEditSpike/hosted-inputs.pin.json'
        hosted_proof = hosted_module.validate_inputs(
            sdk, args.hosted_inputs, hosted_pin, args.hosted_rustup_home, args.hosted_cargo)
        hosted_provenance = {'profile': 'hosted-sdk9-public-source', 'checkpointSHA256': args.hosted_checkpoint_sha256,
                             'pinSHA256': HOSTED_PIN_SHA256,
                             'cargoCommit': hosted_proof['cargoCommit'],
                             'sourceInventorySHA256': sha(json.dumps(hosted_proof, sort_keys=True, separators=(',', ':')).encode()),
                             'networkRouteProven': False}
        staged_vendor = out / 'hosted-vendor'
        shutil.copytree(args.hosted_inputs / 'vendor', staged_vendor, symlinks=False)
        if hosted_module.inventory(staged_vendor) != hosted_proof['vendor']:
            raise ValueError('hosted vendor changed during copy')
        raw_config = (args.hosted_inputs / 'vendor-config.toml').read_text()
        (cargo_home / 'config.toml').write_text(hosted_module.replacement_config(
            raw_config, args.hosted_inputs / 'vendor', staged_vendor))
    else:
        shutil.copytree(args.cargo_registry, cargo_home / 'registry', symlinks=True)
        shutil.copytree(args.cargo_git, cargo_home / 'git', symlinks=True)
        _, copied_hash, copied_count = file_inventory(cargo_home / 'registry')
        _, source_hash, source_count = file_inventory(args.cargo_registry)
        if (copied_hash, copied_count, source_hash, source_count) != (registry_hash, registry_count, registry_hash, registry_count):
            raise ValueError('offline registry changed during copy')
        _, copied_git_hash, copied_git_count = file_inventory(cargo_home / 'git', allow_git_dirs=True)
        _, source_git_hash, source_git_count = file_inventory(args.cargo_git, allow_git_dirs=True)
        if (copied_git_hash, copied_git_count, source_git_hash, source_git_count) != (git_hash, git_count, git_hash, git_count):
            raise ValueError('offline git cache changed during copy')
    target = out / 'cargo-target'
    env = dict(env, CARGO_HOME=str(cargo_home), CARGO_TARGET_DIR=str(target),
               CARGO_NET_OFFLINE='true', CARGO_BUILD_JOBS='2', RUSTUP_AUTO_INSTALL='0',
               RUSTUP_NO_UPDATE_CHECK='1', MACOSX_DEPLOYMENT_TARGET='26.0',
               CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS='false', CARGO_PROFILE_DEV_DEBUG_ASSERTIONS='true',
               RUSTFLAGS='-C link-arg=-mmacosx-version-min=26.0 --cfg bitwarden_ensure_non_commercial')
    common = ['--offline', '--locked', '--jobs', '2', '--manifest-path', str(sdk / 'Cargo.toml'),
              '--target', 'aarch64-apple-darwin']
    cargo_cmd = [str(args.hosted_cargo)] if hosted else ['cargo', '+1.98.0']
    run(helper, [*cargo_cmd, 'build', *common, '--release', '--package', 'uniffi-bindgen'], sdk, env)
    bindgen = target / 'aarch64-apple-darwin/release/uniffi-bindgen'
    require_regular(bindgen)
    generator_hash = digest(bindgen)
    receipts = {}
    release_binding = None
    for mode in ('release', 'debug'):
        flags = ['--release'] if mode == 'release' else []
        run(helper, [*cargo_cmd, 'rustc', *common, *flags, '--package', 'bitwarden-uniffi', '--',
                     '-C', 'link-arg=-Wl,-install_name,@rpath/libbitwarden_uniffi.dylib'], sdk, env)
        dylib = target / 'aarch64-apple-darwin' / mode / 'libbitwarden_uniffi.dylib'
        require_regular(dylib)
        dylib_hash = digest(dylib)
        if run(helper, ['lipo', '-archs', str(dylib)], ROOT, env, 30).strip() != 'arm64':
            raise ValueError('dylib architecture mismatch')
        if not re.search(r'minos\s+26\.0(?:\s|$)', run(helper, ['vtool', '-show-build', str(dylib)], ROOT, env, 30)):
            raise ValueError('dylib deployment target mismatch')
        if run(helper, ['otool', '-D', str(dylib)], ROOT, env, 30).splitlines()[1:] != ['@rpath/libbitwarden_uniffi.dylib']:
            raise ValueError('dylib install name mismatch')
        generated = out / ('generated-' + mode)
        generated.mkdir()
        run(helper, [str(bindgen), 'generate', str(dylib), '--language', 'swift', '--no-format', '--out-dir', str(generated)], sdk, env, 900)
        binding = generated_files(generated)
        if mode == 'release':
            release_binding = binding
        elif binding != release_binding:
            raise ValueError('release/debug generated bindings differ')
        if digest(bindgen) != generator_hash or digest(dylib) != dylib_hash:
            raise ValueError('generator or dylib changed')
        pkg = out / ('Package-' + mode)
        manifest = stage_package(helper, sdk, generated, dylib, pkg, pin, mode, binding, profile, hosted_provenance)
        manifest_hash = digest(pkg / 'build-manifest.json')
        _, package_before_hash, package_before_count = file_inventory(pkg)
        consumer_dir = out / ('consumer-' + mode)
        (consumer_dir / 'Sources/StrictSDKConsumer').mkdir(parents=True)
        (consumer_dir / 'Sources/StrictSDKConsumer/main.swift').write_bytes(consumer)
        package_swift = ('// swift-tools-version: 5.9\nimport PackageDescription\n'
                         'let package = Package(name: "StrictSDKConsumer", platforms: [.macOS("26.0")], '
                         'dependencies: [.package(path: ' + json.dumps(str(pkg)) + ')], '
                         'targets: [.executableTarget(name: "StrictSDKConsumer", '
                         'dependencies: [.product(name: "ArcusisBitwardenSDK", package: "Package-' + mode + '")])])\n')
        (consumer_dir / 'Package.swift').write_text(package_swift)
        scratch = out / ('swift-build-' + mode)
        cache = out / ('swift-cache-' + mode)
        cache.mkdir()
        swift = ['swift', 'build', '--jobs', '2', '--package-path', str(consumer_dir),
                 '--scratch-path', str(scratch), '--cache-path', str(cache), '--disable-dependency-cache',
                 '--disable-keychain', '--disable-netrc', '--disable-prefetching', '--manifest-cache', 'none',
                 '--disable-sandbox']
        library = pkg / 'Frameworks/BitwardenSDK.xcframework/macos-arm64'
        run(helper, swift + ['--product', 'StrictSDKConsumer', '-Xlinker', '-rpath', '-Xlinker',
                            str(library)], out, env, 1800)
        bin_dir = Path(run(helper, swift + ['--show-bin-path'], out, env, 60).strip())
        executable = bin_dir / 'StrictSDKConsumer'
        if not bin_dir.is_absolute() or not bin_dir.is_relative_to(scratch):
            raise ValueError('consumer executable outside owned scratch')
        require_regular(executable)
        consumer_binary_hash = digest(executable)
        if run(helper, ['lipo', '-archs', str(executable)], out, env, 30).strip() != 'arm64':
            raise ValueError('consumer architecture mismatch')
        if not re.search(r'minos\s+26\.0(?:\s|$)',
                         run(helper, ['vtool', '-show-build', str(executable)], out, env, 30)):
            raise ValueError('consumer deployment target mismatch')
        if '@rpath/libbitwarden_uniffi.dylib' not in run(helper, ['otool', '-L', str(executable)], out, env, 30):
            raise ValueError('consumer SDK linkage missing')
        rpaths = run(helper, ['otool', '-l', str(executable)], out, env, 30)
        if not re.search(r'cmd LC_RPATH\s+cmdsize \d+\s+path ' + re.escape(str(library)) + r' \(offset \d+\)', rpaths):
            raise ValueError('consumer rpath mismatch')
        verify_source(helper, sdk, pin, env)
        if digest(dylib) != dylib_hash or digest(bindgen) != generator_hash or generated_files(generated) != binding:
            raise ValueError('build artifacts changed after consumer compilation')
        package_inventory = validate_package_inventory(pkg, set(manifest['fileSHA256']) | {'build-manifest.json'})
        _, package_after_hash, package_after_count = file_inventory(pkg)
        if (package_after_hash, package_after_count) != (package_before_hash, package_before_count):
            raise ValueError('package metadata changed after compilation')
        if digest(executable) != consumer_binary_hash:
            raise ValueError('consumer executable changed')
        if (digest(pkg / 'build-manifest.json') != manifest_hash or
                json_bytes((pkg / 'build-manifest.json').read_bytes()) != manifest or
                any(package_inventory.get(k) != v for k, v in manifest['fileSHA256'].items()) or
                set(package_inventory) != set(manifest['fileSHA256']) | {'build-manifest.json'}):
            raise ValueError('package changed after consumer compilation')
        receipts[mode] = {'manifestSHA256': digest(pkg / 'build-manifest.json'),
                          'dylibSHA256': dylib_hash, 'files': package_inventory,
                          'inventorySHA256': package_after_hash, 'inventoryEntries': package_after_count,
                          'consumerBinarySHA256': consumer_binary_hash,
                          'testOnly': mode == 'debug', 'consumerCompiled': True, 'consumerExecuted': False}
    if hosted:
        if (hosted_module.validate_inputs(sdk, args.hosted_inputs, hosted_pin,
                                          args.hosted_rustup_home, args.hosted_cargo) != hosted_proof or
            hosted_module.inventory(staged_vendor) != hosted_proof['vendor'] or
            digest(args.hosted_checkpoint) != args.hosted_checkpoint_sha256):
            raise ValueError('hosted inputs changed during build')
        for name, item in hosted_paths.items():
            if digest(item) != json_bytes(args.hosted_checkpoint.read_bytes())['files'][name]:
                raise ValueError('hosted checkpoint source changed')
    else:
        _, final_registry_hash, final_registry_count = file_inventory(args.cargo_registry)
        if (final_registry_hash, final_registry_count) != (registry_hash, registry_count):
            raise ValueError('offline registry changed during build')
        _, final_git_hash, final_git_count = file_inventory(args.cargo_git, allow_git_dirs=True)
        if (final_git_hash, final_git_count) != (git_hash, git_count):
            raise ValueError('offline git cache changed during build')
    if digest(args.legacy_builder) != LEGACY_SHA256 or digest(args.consumer_source) != pin['consumerSHA256']:
        raise ValueError('reviewed helper or consumer changed during build')
    if digest(args.source_review) != SOURCE_REVIEW:
        raise ValueError('source review changed during build')
    if digest(args.write_candidate) != base_pin['writeCandidateSHA256'] or digest(profile.pin) != args.pin_sha256:
        raise ValueError('reviewed inputs changed after build')
    if profile == SDK9_PROFILE:
        if (digest(base_path) != SDK8_PIN_SHA256 or digest(args.service_patch) != SERVICE_PATCH_SHA256 or
                digest(args.service_candidate) != SERVICE_CANDIDATE_SHA256 or
                digest(args.service_source_review) != SERVICE_REVIEW_SHA256):
            raise ValueError('SDK9 reviewed inputs changed during build')
        verify_primary_sources(args.service_primary, service_candidate)
        verify_service_transition(helper, sdk, pin, service_candidate, env)
    for entry in base_pin['patches']:
        if digest(under(args.patch_root, entry['path'])) != entry['sha256']:
            raise ValueError('patch changed during build')
    receipt = {'schema': 1, 'accepted': False, 'integrationReady': False,
               'pinSHA256': args.pin_sha256, 'sourceCommit': COMMIT, 'sourceGitTree': TREE,
               'candidateGitTree': pin['candidateGitTree'], 'candidateCargoLockSHA256': pin['candidateCargoLockSHA256'],
               'fullDiffSHA256': pin['fullDiffSHA256'], 'patches': pin['patches'],
               'sourceManifestSHA256': pin['sourceManifestSHA256'], 'bindgenSHA256': generator_hash,
               'consumerSHA256': pin['consumerSHA256'], 'packages': receipts,
               'commands': helper.COMMANDS, 'logSHA256': file_inventory(out / 'logs')[0]}
    if profile == SDK9_PROFILE:
        receipt.update(profile='sdk9-service-shapes', sdk8PinSHA256=SDK8_PIN_SHA256,
                       serviceCandidateSHA256=SERVICE_CANDIDATE_SHA256,
                       serviceReviewSHA256=SERVICE_REVIEW_SHA256, servicePatchSHA256=SERVICE_PATCH_SHA256)
    if hosted_provenance is not None:
        receipt['hostedInputProvenance'] = hosted_provenance
    (out / 'receipt.json').write_text(json.dumps(receipt, sort_keys=True, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'strict-sdk: {type(error).__name__}: {error}', file=sys.stderr)
        sys.exit(1)
