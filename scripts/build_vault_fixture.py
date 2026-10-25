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
    seen = set()
    kinds = {}
    for member in members:
        path = PurePosixPath(member.name)
        canonical = path.as_posix()
        if (path.is_absolute() or '..' in path.parts or not path.parts
                or path.parts[0] != prefix
                or member.name not in (canonical, canonical + '/')
                or (member.name.endswith('/') and not member.isdir())
                or canonical in seen
                or not (member.isdir() or member.isfile() or member.issym())):
            raise RuntimeError('Unsupported or escaping vault fixture archive member')
        seen.add(canonical)
        kind = 'dir' if member.isdir() else 'file' if member.isfile() else 'symlink'
        if canonical == prefix and kind != 'dir':
            raise RuntimeError('Vault fixture archive source root is not a directory')
        kinds[canonical] = kind
        if member.issym():
            link = PurePosixPath(member.linkname)
            target = list(path.parent.parts)
            if link.is_absolute():
                raise RuntimeError('Vault fixture archive symlink escaped its source root')
            for part in link.parts:
                if part in ('', '.'):
                    continue
                if part == '..':
                    if len(target) <= 1:
                        raise RuntimeError('Vault fixture archive symlink escaped its source root')
                    target.pop()
                else:
                    target.append(part)
            if not target or target[0] != prefix:
                raise RuntimeError('Vault fixture archive symlink escaped its source root')
    for member_path, kind in kinds.items():
        path = PurePosixPath(member_path)
        for length in range(1, len(path.parts)):
            parent = PurePosixPath(*path.parts[:length]).as_posix()
            if kinds.get(parent, 'dir') != 'dir':
                raise RuntimeError('Vault fixture archive has conflicting source paths')
        if kind != 'dir' and any(other.startswith(member_path + '/') for other in kinds):
            raise RuntimeError('Vault fixture archive has conflicting source paths')
    return members


def verify_source(archive, destination, prefix):
    members = source_members(archive, prefix)
    expected = {prefix: 'dir'}
    for member in members:
        path = PurePosixPath(member.name)
        for length in range(1, len(path.parts)):
            parent = PurePosixPath(*path.parts[:length]).as_posix()
            if expected.get(parent) not in (None, 'dir'):
                raise RuntimeError('Vault fixture archive has conflicting source paths')
            expected[parent] = 'dir'
        kind = 'dir' if member.isdir() else 'file' if member.isfile() else 'symlink'
        canonical = path.as_posix()
        if canonical in expected and expected[canonical] != kind:
            raise RuntimeError('Vault fixture archive has conflicting source paths')
        expected[canonical] = kind

    root = (destination / prefix).resolve()
    for member in members:
        target = destination / member.name
        if not target.resolve().is_relative_to(root):
            raise RuntimeError('Vault fixture source escaped its cache')
        if member.issym():
            if not target.is_symlink() or os.readlink(target) != member.linkname:
                raise RuntimeError('Vault fixture source symlink differs from its archive')
        elif target.is_symlink():
            raise RuntimeError('Vault fixture source file was replaced by a symlink')
        if member.isfile():
            if not target.is_file():
                raise RuntimeError('Vault fixture source is incomplete')
            expected_digest = hashlib.sha256(archive.extractfile(member).read()).hexdigest()
            if digest(target) != expected_digest:
                raise RuntimeError('Vault fixture source differs from its verified archive')

    actual = {prefix: 'dir'}
    pending = [destination / prefix]
    while pending:
        directory = pending.pop()
        if directory.is_symlink() or not directory.is_dir():
            raise RuntimeError('Vault fixture source directory was replaced')
        for entry in os.scandir(directory):
            path = Path(entry.path)
            relative = path.relative_to(destination).as_posix()
            if entry.is_symlink():
                actual[relative] = 'symlink'
            elif entry.is_dir(follow_symlinks=False):
                actual[relative] = 'dir'
                pending.append(path)
            elif entry.is_file(follow_symlinks=False):
                actual[relative] = 'file'
            else:
                raise RuntimeError('Unsupported vault fixture source file type')
    if actual != expected:
        raise RuntimeError('Vault fixture source tree has unexpected or missing inputs')


def valid_receipt(receipt_file, binary, pin, fingerprint, source):
    try:
        receipt = json.loads(receipt_file.read_text())
        return (type(receipt.get('schema')) is int and receipt.get('schema') == 1
                and receipt.get('pinSHA256') == fingerprint
                and receipt.get('sourceCommit') == pin['sourceCommit']
                and receipt.get('rustToolchain') == pin['rustToolchain']
                and receipt.get('binarySHA256') == digest(binary)
                and receipt.get('cargoLockSHA256') == digest(source / 'Cargo.lock'))
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        return False


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
        if valid_receipt(receipt_file, binary, pin, fingerprint, source):
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
