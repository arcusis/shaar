#!/usr/bin/env python3
"""Acquire public SDK9 Cargo inputs and validate their locked source bytes.

Run only on an explicitly approved hosted worker. Importing this module is inert.
"""
from __future__ import annotations

import argparse
import configparser
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import tarfile
import tempfile
import time
import tomllib

PIN_SHA = 'c7f71d14a29abfa5a4dca441c49fce5e6a87127d4fff8a206af793b9558b3489'
LOCK_SHA = '48cef19482dfc18bbaf67e233b756a0b2a8e1551e558384893f0c05d3d7efd3e'
TREE = 'd43b3922107fb7e760090cb9ec18715c73776b2a'
COMMIT = '043279e92e2eb5f509bf87eb7fa50987fd377e32'
GIT_TREE = 'e6f5aece3d5a7fa346fda8ca688ac8280ff419be'
REGISTRY = 'registry+https://github.com/rust-lang/crates.io-index'
GIT = 'git+https://github.com/bitwarden/passkey-rs?rev=' + COMMIT + '#' + COMMIT
NAME = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_-]*$')
VERSION = re.compile(r'^[0-9][A-Za-z0-9.+_-]*$')
HASH = re.compile(r'^[0-9a-f]{64}$')
NO_NETWORK = '(version 1)(allow default)(deny network*)'
SOURCE_CONFIG_SHA = 'b6d973a24da7644ebf4d8520af23722350ea06e32985a70d80d2eef96368c9f3'
CARGO_CHECKSUM_COMMENT = 'This file only protects against accidental modifications. It is not a security mechanism and does not protect against malicious changes.'
CARGO_COMMIT = '797e8a9bca276c1c9f9f738d2a20f484fa4eea9d'


def digest(path: Path) -> str:
    return hashlib.sha256(regular(path).read_bytes()).hexdigest()


def regular(path: Path) -> Path:
    if (not path.is_absolute() or path.resolve(strict=True) != path or
        any(p.is_symlink() for p in (path, *path.parents)) or not stat.S_ISREG(path.lstat().st_mode)):
        raise ValueError('unsafe file')
    return path


def directory(path: Path) -> Path:
    if (not path.is_absolute() or path.resolve(strict=True) != path or
        any(p.is_symlink() for p in (path, *path.parents)) or not stat.S_ISDIR(path.lstat().st_mode)):
        raise ValueError('unsafe directory')
    return path


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate JSON key')
        result[key] = value
    return result


def parse_lock(raw: bytes):
    data = tomllib.loads(raw.decode('utf-8'))
    if not isinstance(data.get('package'), list):
        raise ValueError('missing packages')
    remote, seen = {}, set()
    for item in data['package']:
        name, version, source = item.get('name'), item.get('version'), item.get('source')
        if (not isinstance(name, str) or not NAME.fullmatch(name) or not isinstance(version, str)
            or not VERSION.fullmatch(version)):
            raise ValueError('invalid package identity')
        key = (name, version, source)
        if key in seen:
            raise ValueError('duplicate package')
        seen.add(key)
        if source is None:
            continue
        if source not in (REGISTRY, GIT) or (name, version) in remote:
            raise ValueError('unknown or ambiguous source')
        checksum = item.get('checksum')
        if source == REGISTRY:
            if not isinstance(checksum, str) or not HASH.fullmatch(checksum):
                raise ValueError('invalid checksum')
        elif checksum is not None:
            raise ValueError('unexpected git checksum')
        remote[(name, version)] = (source, checksum)
    return remote


def load_pin(path: Path, lock: Path):
    if digest(path) != PIN_SHA or digest(lock) != LOCK_SHA:
        raise ValueError('pin or lock mismatch')
    pin = json.loads(regular(path).read_bytes(), object_pairs_hook=unique)
    if (pin.get('profile') != 'hosted-sdk9-public-source' or pin.get('accepted') is not False
        or pin.get('integrationReady') is not False or pin.get('cargoLockSHA256') != LOCK_SHA
        or pin.get('sdkCandidateTree') != TREE or pin.get('gitCommit') != COMMIT
        or pin.get('gitTree') != GIT_TREE or pin.get('registrySource') != REGISTRY
        or pin.get('gitSource') != GIT or pin.get('cargoCommit') != CARGO_COMMIT):
        raise ValueError('hosted pin provenance')
    packages = parse_lock(regular(lock).read_bytes())
    if sum(source == REGISTRY for source, _ in packages.values()) != 657 or sum(
        source == GIT for source, _ in packages.values()) != 6:
        raise ValueError('dependency count')
    return pin, packages


def inventory(root: Path):
    directory(root)
    files = {}
    for current, dirs, names in os.walk(root, followlinks=False):
        for name in sorted(dirs + names):
            path = Path(current) / name
            mode = path.lstat().st_mode
            if stat.S_ISDIR(mode):
                continue
            if not stat.S_ISREG(mode):
                raise ValueError('symlink or special file')
            rel = path.relative_to(root).as_posix()
            files[rel] = {'sha256': digest(path), 'executable': bool(mode & 0o111)}
    return files


def verify_archives(cargo_home: Path, packages):
    cache = directory(cargo_home / 'registry/cache')
    origins = list(cache.iterdir())
    if len(origins) != 1:
        raise ValueError('unexpected registry caches')
    files = inventory(origins[0])
    expected = {f'{name}-{version}.crate': checksum
                for (name, version), (source, checksum) in packages.items() if source == REGISTRY}
    if set(files) != set(expected) or any(files[name]['sha256'] != checksum for name, checksum in expected.items()):
        raise ValueError('crate inventory or checksum mismatch')
    return expected


def verify_vendor(vendor: Path, packages):
    directory(vendor)
    children = list(vendor.iterdir())
    if any(not child.is_dir() or child.is_symlink() for child in children):
        raise ValueError('invalid vendor member')
    seen = set()
    for child in children:
        directory(child)
        package = tomllib.loads(regular(child / 'Cargo.toml').read_text())['package']
        key = (package.get('name'), package.get('version'))
        if key not in packages or key in seen or child.name != f'{key[0]}-{key[1]}':
            raise ValueError('vendor package membership')
        seen.add(key)
        checks = json.loads(regular(child / '.cargo-checksum.json').read_bytes(), object_pairs_hook=unique)
        if (set(checks) != {'$comment', 'files', 'package'} or checks['$comment'] != CARGO_CHECKSUM_COMMENT
            or checks['package'] != packages[key][1] or not isinstance(checks['files'], dict)):
            raise ValueError('vendor checksum metadata')
        files = inventory(child)
        files.pop('.cargo-checksum.json')
        if ({name: entry['sha256'] for name, entry in files.items()} != checks['files']):
            raise ValueError('vendor file inventory mismatch')
    if seen != set(packages):
        raise ValueError('missing vendor packages')
    return inventory(vendor)


def cargo_ignored(relative: str) -> bool:
    parts = relative.split('/')
    return ('.git' in parts or parts[-1] in ('.gitignore', '.gitattributes') or
            relative == '.cargo-ok')


def verify_registry_vendor(cargo_home: Path, vendor: Path, packages):
    roots = list(directory(cargo_home / 'registry/cache').iterdir())
    if len(roots) != 1:
        raise ValueError('registry cache')
    for (name, version), (source, checksum) in packages.items():
        if source != REGISTRY:
            continue
        raw = regular(roots[0] / f'{name}-{version}.crate').read_bytes()
        if len(raw) > 128 * 1024 * 1024 or hashlib.sha256(raw).hexdigest() != checksum:
            raise ValueError('crate digest')
        expected, seen, total, members = {}, set(), 0, 0
        prefix = f'{name}-{version}/'
        with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as archive:
            for member in archive:
                members += 1
                if members > 50000:
                    raise ValueError('archive bound')
                path = member.name.rstrip('/')
                if (not path or path.startswith('/') or '\\' in path or
                    any(part in ('', '.', '..') for part in path.split('/')) or
                    not (path == prefix[:-1] or path.startswith(prefix)) or
                    not (member.isfile() or member.isdir())):
                    raise ValueError('unsafe crate archive')
                if member.isfile():
                    relative = path[len(prefix):]
                    if not relative or relative in seen:
                        raise ValueError('duplicate archive file')
                    seen.add(relative)
                    total += member.size
                    if total > 512 * 1024 * 1024:
                        raise ValueError('archive bound')
                    if cargo_ignored(relative):
                        continue
                    stream = archive.extractfile(member)
                    if stream is None:
                        raise ValueError('archive file missing')
                    data = stream.read(member.size + 1)
                    if len(data) != member.size:
                        raise ValueError('archive file truncated')
                    expected[relative] = {'sha256': hashlib.sha256(data).hexdigest(),
                                          'executable': bool(member.mode & 0o111)}
        actual = inventory(vendor / f'{name}-{version}')
        actual.pop('.cargo-checksum.json')
        if expected != actual:
            raise ValueError('vendor differs from locked crate')


def environment(home: Path, cargo_home: Path, rustup_home: Path):
    tool_bin = directory(rustup_home / 'toolchains/1.98.0-aarch64-apple-darwin/bin')
    regular(tool_bin / 'cargo')
    regular(tool_bin / 'rustc')
    return {'PATH': str(tool_bin) + ':/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
            'HOME': str(home), 'CARGO_HOME': str(cargo_home), 'RUSTUP_HOME': str(rustup_home),
            'RUSTUP_AUTO_INSTALL': '0', 'RUSTUP_NO_UPDATE_CHECK': '1',
            'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
            'GIT_TERMINAL_PROMPT': '0', 'GIT_LFS_SKIP_SMUDGE': '1',
            'GIT_CONFIG_COUNT': '2', 'GIT_CONFIG_KEY_0': 'credential.helper', 'GIT_CONFIG_VALUE_0': '',
            'GIT_CONFIG_KEY_1': 'core.hooksPath', 'GIT_CONFIG_VALUE_1': '/dev/null',
            'CARGO_NET_GIT_FETCH_WITH_CLI': 'true'}


def command(argv, cwd, env, *, offline=True):
    if offline:
        argv = ['/usr/bin/sandbox-exec', '-p', NO_NETWORK, *argv]
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                   stdout=output, stderr=errors, start_new_session=True)
        primary = cleanup = None
        try:
            deadline = time.monotonic() + 1800
            while os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is None:
                if time.monotonic() >= deadline:
                    raise subprocess.TimeoutExpired(argv, 1800)
                time.sleep(0.05)
        except BaseException as error:
            primary = error
        try:
            # WNOWAIT keeps the leader unreaped, preventing process-group ID reuse
            # until the owned group has been signalled, even if the leader exited.
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            # An exited leader may be the only remaining member and already
            # unsignalable; its unreaped PID still cannot be reused.
            pass
        except PermissionError:
            # A group containing only an exited leader may be unsignalable on
            # macOS. Treat this as unknown until post-reap observation.
            pass
        except BaseException as error:
            cleanup = error
        try:
            process.wait(timeout=5)
            deadline = time.monotonic() + 5
            while True:
                try:
                    os.killpg(process.pid, 0)
                except ProcessLookupError:
                    break
                except PermissionError:
                    # Visibility can lag group termination; EPERM is not proof
                    # that the process group has disappeared.
                    pass
                if time.monotonic() >= deadline:
                    raise ValueError('process group survived')
                time.sleep(0.05)
        except BaseException as error:
            if cleanup is None:
                cleanup = error
        output.seek(0)
        errors.seek(0)
        stdout, stderr = output.read(), errors.read()
        if primary is None and process.returncode != 0:
            text = stderr.decode('utf-8', errors='replace').splitlines()
            safe = next((line for line in text if line.startswith(('error:', 'fatal:', 'sandbox-exec:'))), '')
            safe = ''.join(ch for ch in safe if 32 <= ord(ch) <= 126)[:512]
            primary = ValueError(f'owned command failed ({process.returncode}): {safe}')
        if primary is not None:
            if cleanup is not None:
                primary.add_note(f'owned process cleanup failed: {type(cleanup).__name__}')
            raise primary
        if cleanup is not None:
            raise cleanup
        return stdout.decode('utf-8')


def verify_worktree(source: Path, tree_output: str):
    expected = {}
    expected_dirs = set()
    for line in filter(None, tree_output.split('\0')):
        metadata, name = line.split('\t', 1)
        mode, kind, blob = metadata.split(' ')
        parts = name.split('/')
        if (mode not in ('100644', '100755') or kind != 'blob' or not name or name.startswith('/')
            or '\\' in name or any(part in ('', '.', '..', '.git') for part in parts) or name in expected):
            raise ValueError('unsupported source tree entry')
        expected[name] = (mode == '100755', blob)
        expected_dirs.update('/'.join(parts[:i]) for i in range(1, len(parts)))
    if not expected:
        raise ValueError('empty source tree')
    actual, actual_dirs = {}, set()
    for current, dirs, names in os.walk(source, followlinks=False):
        here = Path(current)
        if here == source and '.git' in dirs:
            dirs.remove('.git')
        for name in sorted(dirs + names):
            path = here / name
            if here == source and name == '.git':
                continue
            mode = path.lstat().st_mode
            rel = path.relative_to(source).as_posix()
            if stat.S_ISDIR(mode):
                actual_dirs.add(rel)
            elif stat.S_ISREG(mode):
                data = path.read_bytes()
                blob = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
                actual[rel] = (bool(mode & 0o111), blob)
            else:
                raise ValueError('unsafe source entry')
    if actual != expected or actual_dirs != expected_dirs:
        raise ValueError('source worktree differs from pinned tree')


def safe_git_config(git_dir: Path, *, origin: str | None, allow_local_origin=False):
    directory(git_dir)
    if (git_dir / 'objects/info/alternates').exists() or (git_dir / 'objects/info/alternates').is_symlink():
        raise ValueError('git alternates rejected')
    config = configparser.RawConfigParser(strict=True)
    config.read_string(regular(git_dir / 'config').read_text())
    allowed_core = {'bare', 'repositoryformatversion', 'filemode', 'ignorecase',
                    'precomposeunicode', 'logallrefupdates', 'autocrlf'}
    for section in config.sections():
        keys = set(config[section])
        if section == 'core' and keys <= allowed_core:
            continue
        if section == 'remote "origin"' and keys <= {'url', 'fetch'}:
            value = config[section].get('url', '')
            if value == origin or (allow_local_origin and value.startswith('/')):
                continue
        if section.startswith('branch "') and section.endswith('"') and keys <= {'remote', 'merge'}:
            continue
        raise ValueError('unsafe git config')


def source_check(source: Path, env):
    directory(source)
    safe_git_config(source / '.git', origin=None, allow_local_origin=True)
    for parent in source.parents:
        if any((parent / '.cargo' / name).exists() or (parent / '.cargo' / name).is_symlink()
               for name in ('config', 'config.toml')):
            raise ValueError('parent Cargo configuration rejected')
    if digest(source / 'Cargo.lock') != LOCK_SHA:
        raise ValueError('source lock mismatch')
    config_path = source / '.cargo/config.toml'
    if digest(config_path) != SOURCE_CONFIG_SHA or set(tomllib.loads(config_path.read_text())) != {'resolver', 'target'}:
        raise ValueError('source Cargo config mismatch')
    if (source / '.cargo/config').exists() or (source / '.cargo/config').is_symlink():
        raise ValueError('unexpected source Cargo config')
    if command(['git', 'write-tree'], source, env).strip() != TREE:
        raise ValueError('source tree mismatch')
    verify_worktree(source, command(['git', 'ls-tree', '-rz', TREE], source, env))


def git_check(cargo_home: Path, env, *, check_checkout=True):
    db = directory(cargo_home / 'git/db')
    repositories = list(db.iterdir())
    if len(repositories) != 1 or not repositories[0].name.startswith('passkey-rs-'):
        raise ValueError('git cache membership')
    repo = directory(repositories[0])
    inventory(repo)
    safe_git_config(repo, origin=None)
    command(['git', '--git-dir', str(repo), 'fsck', '--full', '--no-reflogs', '--no-dangling'], repo, env)
    actual = command(['git', '--git-dir', str(repo), 'rev-parse', COMMIT + '^{tree}'], repo, env).strip()
    if actual != GIT_TREE:
        raise ValueError('git tree mismatch')
    entries = command(['git', '--git-dir', str(repo), 'ls-tree', '-rz', COMMIT], repo, env).split('\0')
    expected = {}
    for line in filter(None, entries):
        metadata, path = line.split('\t', 1)
        mode, kind, blob = metadata.split(' ')
        if (mode not in ('100644', '100755') or kind != 'blob' or not path or path.startswith('/')
            or '\\' in path or any(part in ('', '.', '..', '.git') for part in path.split('/'))
            or path in expected):
            raise ValueError('unsupported git tree entry')
        expected[path] = (mode == '100755', blob)
    if not expected:
        raise ValueError('empty git tree')
    if not check_checkout:
        return {'commit': COMMIT, 'tree': GIT_TREE}
    checkouts = directory(cargo_home / 'git/checkouts')
    groups = list(checkouts.iterdir())
    if len(groups) != 1 or not groups[0].name.startswith('passkey-rs-'):
        raise ValueError('git checkout membership')
    versions = list(directory(groups[0]).iterdir())
    if len(versions) != 1:
        raise ValueError('git checkout count')
    checkout = directory(versions[0])
    checkout_git = directory(checkout / '.git')
    inventory(checkout_git)
    safe_git_config(checkout_git, origin=repo.as_uri())
    actual = {}
    for current, dirs, names in os.walk(checkout, followlinks=False):
        here = Path(current)
        if here == checkout and '.git' in dirs:
            dirs.remove('.git')
        for name in sorted(dirs + names):
            path = here / name
            if here == checkout and name == '.git':
                continue
            if here == checkout and name == '.cargo-ok':
                if regular(path).read_bytes() != b'':
                    raise ValueError('invalid Cargo checkout marker')
                continue
            mode = path.lstat().st_mode
            if stat.S_ISDIR(mode):
                continue
            if not stat.S_ISREG(mode):
                raise ValueError('unsafe git checkout')
            data = path.read_bytes()
            blob = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
            actual[path.relative_to(checkout).as_posix()] = (bool(mode & 0o111), blob)
    if actual != expected:
        raise ValueError('git checkout differs from tree')
    return {'commit': COMMIT, 'tree': GIT_TREE}


def vendor_again(source, cargo_home, env, cargo, destination, packages):
    config = command([str(cargo), 'vendor', '--locked', '--offline', '--respect-source-config',
                      '--versioned-dirs', '--manifest-path', str(source / 'Cargo.toml'), str(destination)], source, env)
    replacement_config(config, destination, destination)
    return verify_vendor(destination, packages), config


def check_cargo_version(cargo, source, env):
    lines = command([str(cargo), '-vV'], source, env).splitlines()
    if ('cargo 1.98.0 (797e8a9bc 2026-08-05)' not in lines or
        'commit-hash: ' + CARGO_COMMIT not in lines or 'host: aarch64-apple-darwin' not in lines):
        raise ValueError('unexpected Cargo identity')


def replacement_config(raw, original: Path, destination: Path):
    data = tomllib.loads(raw)
    if set(data) != {'source'} or not isinstance(data['source'], dict):
        raise ValueError('unexpected vendor config')
    sources = data['source']
    registry = sources.get('crates-io')
    if not isinstance(registry, dict) or set(registry) != {'replace-with'}:
        raise ValueError('unexpected registry source')
    name = registry['replace-with']
    if not isinstance(name, str) or not NAME.fullmatch(name):
        raise ValueError('invalid vendor source name')
    git_sources = [(key, value) for key, value in sources.items() if key not in ('crates-io', name)]
    if len(git_sources) != 1 or set(sources) != {'crates-io', name, git_sources[0][0]}:
        raise ValueError('unexpected vendor sources')
    key, git = git_sources[0]
    if (key != 'git+https://github.com/bitwarden/passkey-rs?rev=' + COMMIT or
        git != {'git': 'https://github.com/bitwarden/passkey-rs', 'rev': COMMIT, 'replace-with': name} or
        sources[name] != {'directory': str(original)}):
        raise ValueError('vendor source identity mismatch')
    return ('[source.crates-io]\nreplace-with = ' + json.dumps(name) + '\n' +
            '[source.' + json.dumps(key) + ']\ngit = "https://github.com/bitwarden/passkey-rs"\n' +
            'rev = ' + json.dumps(COMMIT) + '\nreplace-with = ' + json.dumps(name) + '\n' +
            '[source.' + json.dumps(name) + ']\ndirectory = ' + json.dumps(str(destination)) + '\n')


def validate_inputs(source, root, pin_path, rustup_home, cargo):
    directory(root)
    directory(root / 'home')
    directory(root / 'cargo-home')
    directory(rustup_home)
    regular(cargo)
    if cargo != rustup_home / 'toolchains/1.98.0-aarch64-apple-darwin/bin/cargo':
        raise ValueError('unexpected Cargo executable')
    env = environment(root / 'home', root / 'cargo-home', rustup_home)
    check_cargo_version(cargo, source, env)
    source_check(source, env)
    _, packages = load_pin(pin_path, source / 'Cargo.lock')
    registry_inventory = inventory(root / 'cargo-home/registry')
    git_inventory = inventory(root / 'cargo-home/git')
    archives = verify_archives(root / 'cargo-home', packages)
    git = git_check(root / 'cargo-home', env)
    original = verify_vendor(root / 'vendor', packages)
    verify_registry_vendor(root / 'cargo-home', root / 'vendor', packages)
    raw_config = regular(root / 'vendor-config.toml').read_text()
    replacement_config(raw_config, root / 'vendor', root / 'vendor')
    with tempfile.TemporaryDirectory(prefix='sdk9-verify-') as temporary:
        scratch = Path(temporary).resolve()
        scratch_home, scratch_cargo = scratch / 'home', scratch / 'cargo-home'
        scratch_home.mkdir()
        scratch_cargo.mkdir()
        shutil.copytree(root / 'cargo-home/registry', scratch_cargo / 'registry', symlinks=False)
        (scratch_cargo / 'git').mkdir()
        shutil.copytree(root / 'cargo-home/git/db', scratch_cargo / 'git/db', symlinks=False)
        copied_env = environment(scratch_home, scratch_cargo, rustup_home)
        verify_archives(scratch_cargo, packages)
        git_check(scratch_cargo, copied_env, check_checkout=False)
        regenerated, _ = vendor_again(source, scratch_cargo, copied_env, cargo, scratch / 'vendor', packages)
        git_check(scratch_cargo, copied_env)
    if regenerated != original:
        raise ValueError('vendor regeneration mismatch')
    source_check(source, env)
    if (verify_archives(root / 'cargo-home', packages) != archives or
        git_check(root / 'cargo-home', env) != git or
        inventory(root / 'cargo-home/registry') != registry_inventory or
        inventory(root / 'cargo-home/git') != git_inventory):
        raise ValueError('inputs changed')
    return {'profile': 'hosted-sdk9-public-source', 'lockSHA256': LOCK_SHA,
            'candidateTree': TREE, 'git': git, 'cargoCommit': CARGO_COMMIT, 'archives': archives, 'vendor': original,
            'vendorConfigSHA256': digest(root / 'vendor-config.toml')}


def main():
    parser = argparse.ArgumentParser()
    for flag in ('source', 'pin', 'output', 'rustup-home', 'cargo'):
        parser.add_argument('--' + flag, type=Path, required=True)
    args = parser.parse_args()
    directory(args.source)
    directory(args.rustup_home)
    regular(args.cargo)
    load_pin(args.pin, args.source / 'Cargo.lock')
    if (not args.output.is_absolute() or args.output.exists() or args.output.is_symlink()
        or args.output.parent.resolve(strict=True) != args.output.parent
        or any(p.is_symlink() for p in (args.output.parent, *args.output.parent.parents))):
        raise ValueError('fresh output required')
    args.output.mkdir(mode=0o700)
    receipt = {'schema': 1, 'status': 'failed', 'stage': 'setup', 'accepted': False,
               'integrationReady': False, 'networkRouteProven': False}
    try:
        home, cargo_home = args.output / 'home', args.output / 'cargo-home'
        home.mkdir(mode=0o700)
        cargo_home.mkdir(mode=0o700)
        env = environment(home, cargo_home, args.rustup_home)
        source_check(args.source, env)
        if args.cargo != args.rustup_home / 'toolchains/1.98.0-aarch64-apple-darwin/bin/cargo':
            raise ValueError('unexpected Cargo executable')
        check_cargo_version(args.cargo, args.source, env)
        # Public acquisition is intentionally a separate, approval-gated hosted step.
        receipt['stage'] = 'fetch'
        command([str(args.cargo), 'fetch', '--locked', '--manifest-path',
                 str(args.source / 'Cargo.toml')], args.source, env, offline=False)
        receipt['stage'] = 'source-validation'
        _, packages = load_pin(args.pin, args.source / 'Cargo.lock')
        verify_archives(cargo_home, packages)
        git_check(cargo_home, env)
        source_check(args.source, env)
        receipt['stage'] = 'vendor'
        _, config = vendor_again(args.source, cargo_home, env, args.cargo, args.output / 'vendor', packages)
        (args.output / 'vendor-config.toml').write_text(config)
        receipt['stage'] = 'revalidation'
        proof = validate_inputs(args.source, args.output, args.pin, args.rustup_home, args.cargo)
        receipt.update(proof, status='passed', stage='complete')
    except BaseException as error:
        receipt['errorType'] = type(error).__name__
        if isinstance(error, ValueError):
            receipt['diagnostic'] = ''.join(ch for ch in str(error) if 32 <= ord(ch) <= 126)[:512]
        raise
    finally:
        path = args.output / 'receipt.json'
        with path.open('x', encoding='utf-8') as stream:
            os.chmod(path, 0o600)
            stream.write(json.dumps(receipt, sort_keys=True, indent=2) + '\n')


if __name__ == '__main__':
    main()
