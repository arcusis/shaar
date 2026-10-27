#!/usr/bin/env python3
"""Stage pinned public SDK10 source and toolchain on an approved hosted worker."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import tarfile
import time
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
RUST_URL = 'https://static.rust-lang.org/dist/2026-08-20/rust-1.98.0-aarch64-apple-darwin.tar.xz'
RUST_SHA256 = '5395f380bd220890b89b7e8ce137f3965cf0625b6f561af11e97c8d5c8743c3b'
RUST_ARCHIVE_LIMIT = 500 * 1024 * 1024
RUST_EXPANDED_LIMIT = 4 * 1024 * 1024 * 1024
PRIMARY_LIMIT = 4 * 1024 * 1024
UPSTREAM = 'https://github.com/bitwarden/sdk-internal.git'
SERVICE_SHA = '9a202a82c43c72c116f2748683adb6c197be7c441ca41d83a5f31c906f20c50d'
HOSTED_PIN_SHA = 'ecbc2ca8e4e3b5102afca1809d928d2d05671acb1c2a899ad6361e712ff99085'
UPSTREAM_COMMIT = '5cf919837e83b71c2508bf99344ea57cf5f84e88'


def regular(path: Path) -> Path:
    if (not path.is_absolute() or path.resolve(strict=True) != path or
        any(part.is_symlink() for part in (path, *path.parents)) or
        not stat.S_ISREG(path.lstat().st_mode)):
        raise ValueError('unsafe source input')
    return path


def load_local(name: str, relative: str):
    path = regular(ROOT / relative)
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ValueError('helper import')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def path_component(value: str) -> str:
    if not value or value in ('.', '..') or '/' in value or '\\' in value or '\x00' in value:
        raise ValueError('unsafe name')
    return value


def archive_path(name: str) -> PurePosixPath:
    path = PurePosixPath(name)
    if (not name or name.startswith('/') or '\\' in name or any(ord(c) < 32 or ord(c) == 127 for c in name) or
        any(part in ('', '.', '..') for part in name.rstrip('/').split('/')) or
        not path.parts or path.parts[0] != 'rust-1.98.0-aarch64-apple-darwin'):
        raise ValueError('unsafe toolchain archive path')
    return path


class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        destination = urllib.parse.urlsplit(newurl)
        if (destination.scheme.lower() != 'https' or not destination.hostname or
            destination.username is not None or destination.password is not None):
            raise ValueError('insecure download redirect')
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def download(url: str, destination: Path, expected: str, limit: int) -> None:
    origin = urllib.parse.urlsplit(url)
    if (not destination.is_absolute() or destination.parent.resolve(strict=True) != destination.parent or
        any(part.is_symlink() for part in (destination.parent, *destination.parent.parents)) or
        destination.exists() or destination.is_symlink() or origin.scheme.lower() != 'https'
        or not origin.hostname or origin.username is not None or origin.password is not None):
        raise ValueError('unsafe download')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), HTTPSRedirect())
    request = urllib.request.Request(url, headers={'User-Agent': 'Arcusis-SDK-source-check'})
    digest = hashlib.sha256()
    size = 0
    deadline = time.monotonic() + 1800
    with opener.open(request, timeout=60) as response, destination.open('xb') as output:
        while True:
            if time.monotonic() >= deadline:
                raise TimeoutError('download deadline exceeded')
            block = response.read(1024 * 1024)
            if not block:
                break
            size += len(block)
            if size > limit:
                raise ValueError('download exceeds limit')
            digest.update(block)
            output.write(block)
    if digest.hexdigest() != expected:
        raise ValueError('download checksum mismatch')


def extract_toolchain(archive: Path, destination: Path) -> Path:
    destination.mkdir(mode=0o700)
    seen, expanded = set(), 0
    with tarfile.open(archive, 'r:xz') as bundle:
        for member in bundle:
            path = archive_path(member.name)
            key = str(path)
            if key in seen:
                raise ValueError('duplicate archive entry')
            seen.add(key)
            target = destination.joinpath(*path.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            if not member.isfile() or member.size < 0:
                raise ValueError('unsupported archive member')
            expanded += member.size
            if expanded > RUST_EXPANDED_LIMIT:
                raise ValueError('expanded archive exceeds limit')
            target.parent.mkdir(parents=True, exist_ok=True)
            source = bundle.extractfile(member)
            if source is None:
                raise ValueError('missing archive body')
            with source, target.open('xb') as output:
                shutil.copyfileobj(source, output, 1024 * 1024)
            target.chmod(0o700 if member.mode & 0o111 else 0o600)
    root = destination / 'rust-1.98.0-aarch64-apple-darwin'
    if not (root / 'install.sh').is_file():
        raise ValueError('toolchain installer missing')
    return root


def verify_regular_tree(path: Path) -> None:
    for current, directories, files in os.walk(path, followlinks=False):
        for name in directories + files:
            mode = (Path(current) / name).lstat().st_mode
            if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
                raise ValueError('unsafe staged input')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output
    if (not output.is_absolute() or output.exists() or output.is_symlink() or
        output.parent.resolve(strict=True) != output.parent or
        any(part.is_symlink() for part in (output.parent, *output.parent.parents))):
        raise ValueError('fresh owned output required')
    output.mkdir(mode=0o700)
    receipt = {'schema': 1, 'status': 'failed', 'accepted': False, 'integrationReady': False}
    try:
        builder = load_local('hosted_sdk10_builder', 'scripts/build-native-bitwarden-strict-sdk.py')
        inputs = load_local('hosted_sdk10_inputs', 'scripts/prepare-native-bitwarden-hosted-inputs.py')
        hosted_pin = ROOT / 'ThirdParty/BitwardenStrictEditSpike/hosted-sdk10-inputs.pin.json'
        regular(hosted_pin)
        if builder.digest(hosted_pin) != HOSTED_PIN_SHA:
            raise ValueError('hosted pin drift')
        service_file = ROOT / 'ThirdParty/BitwardenStrictEditSpike/strict-service-shapes.candidate.json'
        regular(service_file)
        if builder.digest(service_file) != SERVICE_SHA:
            raise ValueError('service candidate drift')
        service = builder.json_bytes(service_file.read_bytes())
        sdk8 = builder.load_pin(ROOT / 'ThirdParty/BitwardenStrictEditSpike/sdk-package.pin.json', builder.SDK8_PIN_SHA256)
        sdk9_file = ROOT / 'ThirdParty/BitwardenStrictEditSpike/service-sdk-package.pin.json'
        regular(sdk9_file)
        if builder.digest(sdk9_file) != builder.SERVICE_PIN_SHA256:
            raise ValueError('SDK9 pin drift')
        sdk9 = builder.validate_service_pin(builder.json_bytes(sdk9_file.read_bytes()), sdk8, service)
        candidate_file = ROOT / 'ThirdParty/BitwardenStrictEditSpike/strict-normalization.candidate.json'
        pin_file = ROOT / 'ThirdParty/BitwardenStrictEditSpike/normalization-sdk-package.pin.json'
        regular(candidate_file)
        regular(pin_file)
        if (builder.digest(candidate_file) != builder.NORMALIZATION_CANDIDATE_SHA256 or
            builder.digest(pin_file) != builder.NORMALIZATION_PIN_SHA256):
            raise ValueError('SDK10 pin drift')
        sdk10 = builder.validate_normalization_pin(builder.json_bytes(pin_file.read_bytes()),
                                                    builder.json_bytes(candidate_file.read_bytes()), sdk9)
        archive = output / 'rust.tar.xz'
        download(RUST_URL, archive, RUST_SHA256, RUST_ARCHIVE_LIMIT)
        installer = extract_toolchain(archive, output / 'rust-unpacked')
        rustup_home = output / 'rustup'
        prefix = rustup_home / 'toolchains/1.98.0-aarch64-apple-darwin'
        prefix.parent.mkdir(parents=True)
        home, cargo_home = output / 'home', output / 'cargo-home'
        home.mkdir(mode=0o700); cargo_home.mkdir(mode=0o700)
        base_env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(home),
                    'TMPDIR': str(output), 'GIT_CONFIG_NOSYSTEM': '1',
                    'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_TERMINAL_PROMPT': '0'}
        inputs.command(['/bin/sh', str(installer / 'install.sh'), '--prefix=' + str(prefix),
                        '--disable-ldconfig'], installer, base_env)
        env = inputs.environment(home, cargo_home, rustup_home)
        cargo = prefix / 'bin/cargo'
        inputs.check_cargo_version(cargo, output, env)
        rustc = inputs.command([str(prefix / 'bin/rustc'), '-vV'], output, env)
        if not rustc.startswith('rustc 1.98.0 (88d9e12ae 2026-08-18)\n') or 'host: aarch64-apple-darwin\n' not in rustc:
            raise ValueError('rustc identity mismatch')
        upstream = output / 'upstream'
        upstream.mkdir()
        inputs.command(['git', 'init', '--quiet'], upstream, env)
        # Limit each Git pack/object file to one GiB without changing host settings.
        inputs.command(['/bin/sh', '-c', 'ulimit -f 2097152; exec "$@"', '--',
                        'git', 'fetch', '--no-tags', '--depth=1', UPSTREAM, UPSTREAM_COMMIT],
                       upstream, env, offline=False, size_root=upstream,
                       size_limit=2 * 1024 * 1024 * 1024)
        inputs.command(['git', 'checkout', '--detach', UPSTREAM_COMMIT], upstream, env)
        if (inputs.command(['git', 'rev-parse', 'HEAD^{tree}'], upstream, env).strip() != builder.TREE or
            inputs.command(['git', 'rev-parse', 'HEAD'], upstream, env).strip() != UPSTREAM_COMMIT):
            raise ValueError('upstream identity mismatch')
        primary = output / 'primary'
        primary.mkdir()
        for name, relative in sorted(service['primaryPaths'].items()):
            path_component(name)
            path = PurePosixPath(relative)
            if path.is_absolute() or any(part in ('', '.', '..') for part in relative.split('/')):
                raise ValueError('unsafe primary path')
            provider = 'vaultwarden' if name.startswith('vaultwarden-') else 'bitwarden'
            repository = 'dani-garcia/vaultwarden' if provider == 'vaultwarden' else 'bitwarden/server'
            url = 'https://raw.githubusercontent.com/' + repository + '/' + service['primaryCommits'][provider] + '/' + relative
            download(url, primary / name, service['primarySha256'][name], PRIMARY_LIMIT)
        builder.verify_primary_sources(primary, service)
        candidate = output / 'candidate'
        inputs.command(['git', 'clone', '--local', '--no-hardlinks', '--no-checkout', str(upstream), str(candidate)],
                       output, env)
        inputs.command(['git', 'checkout', '--detach', UPSTREAM_COMMIT], candidate, env)
        for entry in sdk10['patches']:
            patch = ROOT / builder.safe_relative(entry['path'])
            builder.require_regular(patch)
            if builder.digest(patch) != entry['sha256']:
                raise ValueError('patch drift')
            inputs.command(['git', 'apply', '--check', '--whitespace=error', str(patch)], candidate, env)
            inputs.command(['git', 'apply', '--whitespace=error', str(patch)], candidate, env)
        inputs.command(['git', 'add', '-A', '-f'], candidate, env)
        helper = builder.load_packaging_helpers(ROOT / 'scripts/build-native-bitwarden-sdk.py')
        helper.LOG_DIR = output / 'logs'
        builder.verify_source(helper, candidate, sdk10, env, hosted_sdk10=True)
        inputs.source_check(candidate, env, inputs.HOSTED_SDK10)
        verify_regular_tree(primary)
        receipt.update(status='passed', upstreamCommit=UPSTREAM_COMMIT,
                       candidateTree=sdk10['candidateGitTree'], rustArchiveSHA256=RUST_SHA256,
                       serviceCandidateSHA256=SERVICE_SHA, hostedPinSHA256=HOSTED_PIN_SHA,
                       sourceManifestSHA256=sdk10['sourceManifestSHA256'], primary=service['primarySha256'])
    except BaseException as error:
        receipt['errorType'] = type(error).__name__
        if isinstance(error, (ValueError, TimeoutError)):
            receipt['diagnostic'] = ''.join(ch for ch in str(error) if 32 <= ord(ch) <= 126)[:512]
        raise
    finally:
        (output / 'source-receipt.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
