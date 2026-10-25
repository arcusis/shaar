#!/usr/bin/env python3
"""Build the pinned optional test server. Never starts it or accesses vault data."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import urllib.request


REPO = Path(__file__).resolve().parents[1]
PIN_FILE = REPO / 'ThirdParty/VaultwardenFixture/pin.json'
CACHE = REPO / 'build/VaultFixture'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def source_members(archive, prefix):
    members = archive.getmembers()
    for member in members:
        path = PurePosixPath(member.name)
        if (path.is_absolute() or '..' in path.parts or not path.parts
                or path.parts[0] != prefix or not (member.isdir() or member.isfile() or member.issym())):
            raise RuntimeError('Unsupported or escaping vault fixture archive member')
        if member.issym():
            link = PurePosixPath(member.linkname)
            target = path.parent / link
            if link.is_absolute() or '..' in link.parts or target.parts[0] != prefix:
                raise RuntimeError('Vault fixture archive symlink escaped its source root')
    return members


def verify_source(archive, destination, prefix):
    for member in source_members(archive, prefix):
        target = destination / member.name
        if not target.resolve().is_relative_to((destination / prefix).resolve()):
            raise RuntimeError('Vault fixture source escaped its cache')
        if member.issym():
            if not target.is_symlink() or os.readlink(target) != member.linkname:
                raise RuntimeError('Vault fixture source symlink differs from its archive')
        elif target.is_symlink():
            raise RuntimeError('Vault fixture source file was replaced by a symlink')
        if member.isfile():
            if not target.is_file():
                raise RuntimeError('Vault fixture source is incomplete')
            expected = hashlib.sha256(archive.extractfile(member).read()).hexdigest()
            if digest(target) != expected:
                raise RuntimeError('Vault fixture source differs from its verified archive')


def main():
    pin_bytes = PIN_FILE.read_bytes()
    pin = json.loads(pin_bytes)
    fingerprint = hashlib.sha256(pin_bytes).hexdigest()
    CACHE.mkdir(parents=True, exist_ok=True)
    prefix = 'vaultwarden-' + pin['sourceCommit']
    source = CACHE / prefix
    binary = CACHE / 'target/ci/vaultwarden'
    receipt_file = CACHE / 'build-receipt.json'
    archive = CACHE / ('vaultwarden-' + pin['sourceCommit'][:12] + '.tar.gz')
    if not archive.is_file() or digest(archive) != pin['sha256']:
        partial = archive.with_suffix('.partial')
        print('Fetching pinned Vaultwarden source...', flush=True)
        with urllib.request.urlopen(pin['archiveURL'], timeout=60) as remote, partial.open('wb') as output:
            while chunk := remote.read(1024 * 1024):
                output.write(chunk)
        if digest(partial) != pin['sha256']:
            raise RuntimeError('Vault fixture archive checksum mismatch')
        partial.replace(archive)
    with tarfile.open(archive) as package:
        members = source_members(package, prefix)
        if not source.exists():
            package.extractall(CACHE, members=members, filter='data')
        verify_source(package, CACHE, prefix)
    if receipt_file.is_file() and binary.is_file() and not binary.is_symlink():
        receipt = json.loads(receipt_file.read_text())
        if receipt.get('pinSHA256') == fingerprint and receipt.get('binarySHA256') == digest(binary):
            print(binary)
            return
    # Avoid inherited application/registry credentials and user cargo registry configuration.
    environment = {key: os.environ[key] for key in (
        'PATH', 'HOME', 'TMPDIR', 'DEVELOPER_DIR', 'SDKROOT', 'RUSTUP_HOME') if key in os.environ}
    environment.update(CARGO_HOME=str(CACHE / 'cargo'), CARGO_TARGET_DIR=str(CACHE / 'target'),
                       VW_VERSION=pin['version'])
    command = ['cargo', '+' + pin['rustToolchain'], 'build', '--locked', '--profile', 'ci',
               '--jobs', '4', '--features', ','.join(pin['features']),
               '--manifest-path', str(source / 'Cargo.toml')]
    subprocess.run(command, cwd=source, env=environment, check=True)
    if not binary.is_file() or binary.is_symlink():
        raise RuntimeError('Vault fixture build did not produce its binary')
    receipt = dict(schema=1, pinSHA256=fingerprint, sourceCommit=pin['sourceCommit'],
                   rustToolchain=pin['rustToolchain'], binarySHA256=digest(binary),
                   cargoLockSHA256=digest(source / 'Cargo.lock'))
    temporary = receipt_file.with_suffix('.tmp')
    temporary.write_text(json.dumps(receipt, indent=2) + '\n')
    temporary.replace(receipt_file)
    print(binary)


if __name__ == '__main__':
    main()
