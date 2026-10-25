#!/usr/bin/env python3
"""Read-only, bounded comparison of a pinned engine archive and framework."""

from __future__ import annotations

import argparse
import hashlib
import json
import lzma
import os
from pathlib import Path, PurePosixPath
import stat
import struct
import sys
import tarfile
from typing import BinaryIO


CHUNK_SIZE = 1024 * 1024
MAX_ARCHIVE_SIZE = 2 * 1024 * 1024 * 1024
MAX_TOTAL_MEMBER_SIZE = 4 * 1024 * 1024 * 1024
MAX_FRAMEWORK_TOTAL_SIZE = MAX_TOTAL_MEMBER_SIZE
MAX_DECOMPRESSED_ARCHIVE_SIZE = 5 * 1024 * 1024 * 1024
MAX_MEMBER_SIZE = 1024 * 1024 * 1024
MAX_MEMBERS = 200_000
MAX_FRAMEWORK_MEMBERS = MAX_MEMBERS
MAX_PATH_BYTES = 4096
MAX_LOAD_COMMAND_BYTES = 16 * 1024 * 1024
FRAMEWORK_NAME = "Chromium Framework.framework"
MACHO64_MAGIC = b"\xcf\xfa\xed\xfe"
MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca", b"\xca\xfe\xba\xbf",
}
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
CPU_TYPE_ARM64 = 0x0100000C
PAGE_SIZE_ARM64 = 0x4000


class PayloadError(Exception):
    """Input could not be safely compared."""


def _safe_archive_path(raw: str) -> str:
    if not raw or "\x00" in raw or "\\" in raw or raw.startswith("/"):
        raise PayloadError("archive contains unsafe path")
    path = raw[:-1] if raw.endswith("/") else raw
    parts = path.split("/")
    if len(path.encode("utf-8", "surrogateescape")) > MAX_PATH_BYTES or any(
        part in ("", ".", "..") for part in parts
    ):
        raise PayloadError("archive contains unsafe path")
    return path


def _safe_link(path: str, target: str) -> str:
    if not target or "\x00" in target or "\\" in target or target.startswith("/"):
        raise PayloadError("archive contains unsafe symlink")
    parts = list(PurePosixPath(path).parent.parts)
    if parts == ["."]:
        parts = []
    for part in target.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                raise PayloadError("archive contains escaping symlink")
            parts.pop()
        else:
            parts.append(part)
    return target


def _hash_file(stream: BinaryIO) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    stream.seek(0)
    while block := stream.read(CHUNK_SIZE):
        size += len(block)
        if size > MAX_ARCHIVE_SIZE:
            raise PayloadError("archive exceeds size cap")
        digest.update(block)
    return size, digest.hexdigest()


def _archive_stat(stream: BinaryIO) -> os.stat_result:
    info = os.fstat(stream.fileno())
    if not stat.S_ISREG(info.st_mode) or info.st_size <= 0 or info.st_size > MAX_ARCHIVE_SIZE:
        raise PayloadError("archive is not a supported regular file")
    return info


def _same_archive_stat(left: os.stat_result, right: os.stat_result) -> bool:
    return (left.st_dev, left.st_ino, left.st_mode, left.st_size, left.st_mtime_ns, left.st_ctime_ns) == (
        right.st_dev, right.st_ino, right.st_mode, right.st_size, right.st_mtime_ns, right.st_ctime_ns
    )


def _check_archive_unchanged(stream: BinaryIO, path: Path, initial: os.stat_result) -> None:
    try:
        current = _archive_stat(stream)
        named = path.stat(follow_symlinks=False)
    except OSError as error:
        raise PayloadError("archive changed during comparison") from error
    if (not _same_archive_stat(initial, current) or not stat.S_ISREG(named.st_mode)
            or (named.st_dev, named.st_ino) != (initial.st_dev, initial.st_ino)):
        raise PayloadError("archive changed during comparison")


def _open_archive(path: Path) -> BinaryIO:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        named = path.stat(follow_symlinks=False)
        if not stat.S_ISREG(named.st_mode):
            raise PayloadError("archive is not a supported regular file")
        descriptor = os.open(path, flags)
        stream = os.fdopen(descriptor, "rb")
        opened = _archive_stat(stream)
        if (named.st_dev, named.st_ino) != (opened.st_dev, opened.st_ino):
            raise PayloadError("archive changed during comparison")
        return stream
    except OSError as error:
        if "stream" in locals():
            stream.close()
        elif "descriptor" in locals():
            os.close(descriptor)
        raise PayloadError("archive unavailable or unsafe") from error
    except PayloadError:
        if "stream" in locals():
            stream.close()
        elif "descriptor" in locals():
            os.close(descriptor)
        raise


def _open_framework_file(root: Path, relative: str) -> int:
    parts = relative.split("/")
    if not parts or any(part in ("", ".", "..") for part in parts):
        raise PayloadError("framework member path is unsafe")
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    file_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(root, directory_flags)
        for part in parts[:-1]:
            next_descriptor = os.open(part, directory_flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
        result = os.open(parts[-1], file_flags, dir_fd=descriptor)
        os.close(descriptor)
        return result
    except OSError as error:
        if "descriptor" in locals():
            os.close(descriptor)
        raise PayloadError("framework member could not be opened safely") from error


def _hash_framework_file(root: Path, relative: str) -> str:
    digest = hashlib.sha256()
    try:
        descriptor = _open_framework_file(root, relative)
        stream = os.fdopen(descriptor, "rb")
    except OSError as error:
        raise PayloadError("framework member could not be opened safely") from error
    with stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_MEMBER_SIZE:
            raise PayloadError("framework member is not a supported regular file")
        size = 0
        while block := stream.read(CHUNK_SIZE):
            size += len(block)
            if size > MAX_MEMBER_SIZE:
                raise PayloadError("framework member exceeds size cap")
            digest.update(block)
        final = os.fstat(stream.fileno())
        if (size != info.st_size or final.st_size != info.st_size
                or final.st_mtime_ns != info.st_mtime_ns or final.st_ctime_ns != info.st_ctime_ns):
            raise PayloadError("framework member changed during comparison")
    return digest.hexdigest()


def _archive_inventory(archive: BinaryIO) -> tuple[dict[str, dict], str]:
    # tarfile may stop at tar end markers before validating the xz stream footer.
    # Drain xz independently so a truncated or checksum-invalid container fails closed.
    decompressed = 0
    try:
        archive.seek(0)
        with lzma.LZMAFile(archive, "rb") as compressed:
            while block := compressed.read(CHUNK_SIZE):
                decompressed += len(block)
                if decompressed > MAX_DECOMPRESSED_ARCHIVE_SIZE:
                    raise PayloadError("decompressed archive exceeds size cap")
    except (lzma.LZMAError, EOFError, OSError) as error:
        raise PayloadError("archive compression stream is malformed or truncated") from error
    entries: dict[str, dict] = {}
    seen: set[str] = set()
    roots: set[str] = set()
    total = 0
    count = 0
    try:
        archive.seek(0)
        compressed = lzma.LZMAFile(archive, "rb")
        try:
            with tarfile.open(fileobj=compressed, mode="r|") as tar:
                for member in tar:
                    count += 1
                    if count > MAX_MEMBERS:
                        raise PayloadError("archive member count exceeds cap")
                    name = _safe_archive_path(member.name)
                    if name in seen:
                        raise PayloadError("archive contains duplicate path")
                    seen.add(name)
                    if member.size < 0 or member.size > MAX_MEMBER_SIZE:
                        raise PayloadError("archive member exceeds size cap")
                    total += member.size
                    if total > MAX_TOTAL_MEMBER_SIZE:
                        raise PayloadError("archive total size exceeds cap")
                    if member.isdir():
                        kind = "directory"
                    elif member.isreg():
                        kind = "file"
                    elif member.issym():
                        kind = "symlink"
                        _safe_link(name, member.linkname)
                    else:
                        raise PayloadError("archive contains unsupported member type")
                    if name == FRAMEWORK_NAME and kind == "directory":
                        roots.add(name)
                    elif name.endswith("/" + FRAMEWORK_NAME) and kind == "directory":
                        roots.add(name)
                    if kind == "file":
                        source = tar.extractfile(member)
                        if source is None:
                            raise PayloadError("archive member data unavailable")
                        source.close()  # Streaming iteration advances over file data.
                    entries[name] = {"kind": kind, "size": member.size,
                                     "link": member.linkname if kind == "symlink" else None}
        finally:
            compressed.close()
    except (tarfile.TarError, OSError, EOFError) as error:
        raise PayloadError("archive is malformed or truncated") from error
    if len(roots) != 1:
        raise PayloadError("archive must contain one framework root")
    root = next(iter(roots))
    selected: dict[str, dict] = {}
    for name, entry in entries.items():
        if name == root:
            continue
        if name.startswith(root + "/"):
            relative = name[len(root) + 1:]
            if not relative:
                raise PayloadError("archive contains invalid framework member")
            selected[relative] = entry
    _validate_inventory(selected)
    return selected, root


def _validate_inventory(entries: dict[str, dict]) -> None:
    kinds = {path: entry["kind"] for path, entry in entries.items()}
    for path, kind in list(kinds.items()):
        parts = path.split("/")
        for end in range(1, len(parts)):
            parent = "/".join(parts[:end])
            parent_kind = kinds.get(parent)
            if parent_kind is not None and parent_kind != "directory":
                raise PayloadError("inventory has a non-directory parent")
            kinds.setdefault(parent, "directory")
        if kind == "symlink":
            _safe_link(path, entries[path]["link"])
    for path, kind in kinds.items():
        if path not in entries:
            entries[path] = {"kind": kind}


def _framework_inventory(root: Path) -> dict[str, dict]:
    try:
        root_stat = root.lstat()
    except OSError as error:
        raise PayloadError("selected framework is unavailable") from error
    if not stat.S_ISDIR(root_stat.st_mode) or stat.S_ISLNK(root_stat.st_mode):
        raise PayloadError("selected framework root is not a directory")
    entries: dict[str, dict] = {}
    count = 0
    total = 0
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        root_fd = os.open(root, directory_flags)
        opened_root = os.fstat(root_fd)
        if (opened_root.st_dev, opened_root.st_ino) != (root_stat.st_dev, root_stat.st_ino):
            os.close(root_fd)
            raise PayloadError("selected framework changed during inventory")
    except OSError as error:
        raise PayloadError("selected framework inventory is unreadable") from error
    stack = [(root_fd, "")]
    try:
        while stack:
            directory_fd, prefix = stack.pop()
            try:
                with os.scandir(directory_fd) as scan:
                    children = []
                    for child in scan:
                        children.append(child.name)
                        if len(children) > MAX_FRAMEWORK_MEMBERS - count:
                            raise PayloadError("framework member count exceeds cap")
                for name in sorted(children):
                    count += 1
                    relative = f"{prefix}/{name}" if prefix else name
                    _safe_archive_path(relative)
                    info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                    if stat.S_ISDIR(info.st_mode):
                        entries[relative] = {"kind": "directory"}
                        child_fd = os.open(name, directory_flags, dir_fd=directory_fd)
                        opened = os.fstat(child_fd)
                        if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                            os.close(child_fd)
                            raise PayloadError("framework directory changed during inventory")
                        stack.append((child_fd, relative))
                    elif stat.S_ISREG(info.st_mode):
                        if info.st_size > MAX_MEMBER_SIZE:
                            raise PayloadError("framework member exceeds size cap")
                        total += info.st_size
                        if total > MAX_FRAMEWORK_TOTAL_SIZE:
                            raise PayloadError("framework total size exceeds cap")
                        entries[relative] = {"kind": "file", "size": info.st_size}
                    elif stat.S_ISLNK(info.st_mode):
                        target = os.readlink(name, dir_fd=directory_fd)
                        entries[relative] = {"kind": "symlink", "link": _safe_link(relative, target)}
                    else:
                        raise PayloadError("framework contains unsupported file type")
            finally:
                os.close(directory_fd)
    except OSError as error:
        for descriptor, _ in stack:
            os.close(descriptor)
        raise PayloadError("selected framework inventory is unreadable") from error
    except PayloadError:
        for descriptor, _ in stack:
            os.close(descriptor)
        raise
    _validate_inventory(entries)
    return entries


def _read_exact(stream: BinaryIO, size: int) -> bytes:
    blocks = bytearray()
    while len(blocks) < size:
        block = stream.read(size - len(blocks))
        if not block:
            raise PayloadError("Mach-O file is truncated")
        blocks.extend(block)
    return bytes(blocks)


def _macho_layout(prefix: bytes, file_size: int) -> dict | None:
    if prefix[:4] not in MACHO_MAGICS:
        return None
    if prefix[:4] != MACHO64_MAGIC:
        raise PayloadError("unsupported Mach-O format or architecture")
    if len(prefix) < 32:
        raise PayloadError("Mach-O header is truncated")
    magic, cpu, subtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from("<IiiIIIII", prefix)
    if magic != 0xFEEDFACF or cpu != CPU_TYPE_ARM64:
        raise PayloadError("unsupported Mach-O format or architecture")
    if ncmds == 0 or sizeofcmds > MAX_LOAD_COMMAND_BYTES or 32 + sizeofcmds > file_size:
        raise PayloadError("Mach-O load command table is malformed")
    if len(prefix) < 32 + sizeofcmds:
        raise PayloadError("Mach-O load command table is truncated")
    command_end = 32 + sizeofcmds
    offset = 32
    segments = []
    all_segments = []
    signatures = []
    masks = []
    for _ in range(ncmds):
        if offset + 8 > command_end:
            raise PayloadError("Mach-O load command table is malformed")
        command, command_size = struct.unpack_from("<II", prefix, offset)
        if command_size < 8 or command_size % 8 or offset + command_size > command_end:
            raise PayloadError("Mach-O load command is malformed")
        if command == LC_SEGMENT_64:
            if command_size < 72:
                raise PayloadError("Mach-O segment command is truncated")
            name = prefix[offset + 8:offset + 24].split(b"\0", 1)[0]
            vmaddr, vmsize, fileoff, filesize, maxprot, initprot, nsects, segflags = struct.unpack_from(
                "<QQQQiiII", prefix, offset + 24
            )
            expected_size = 72 + nsects * 80
            if (command_size != expected_size or fileoff + filesize > file_size or filesize > vmsize
                    or vmaddr + vmsize > 0xFFFFFFFFFFFFFFFF):
                raise PayloadError("Mach-O segment layout is malformed")
            for section_index in range(nsects):
                section_offset = offset + 72 + section_index * 80
                section_size = struct.unpack_from("<Q", prefix, section_offset + 40)[0]
                section_fileoff, section_alignment = struct.unpack_from("<II", prefix, section_offset + 48)
                section_flags = struct.unpack_from("<I", prefix, section_offset + 64)[0]
                section_type = section_flags & 0xFF
                if section_alignment > 63:
                    raise PayloadError("Mach-O section alignment is malformed")
                if section_type not in (1, 12, 18) and section_size:
                    if (section_fileoff < fileoff or section_fileoff + section_size > fileoff + filesize
                            or section_fileoff + section_size > file_size):
                        raise PayloadError("Mach-O section exceeds its segment")
            all_segments.append((fileoff, fileoff + filesize))
            if name == b"__LINKEDIT":
                if nsects != 0 or initprot & 0x6 or maxprot & 0x6 or not initprot & 0x1:
                    raise PayloadError("Mach-O __LINKEDIT protections or sections are unsupported")
                segments.append({"offset": offset, "fileoff": fileoff, "filesize": filesize,
                                 "vmsize": vmsize, "command_size": command_size})
        elif command == LC_CODE_SIGNATURE:
            if command_size != 16:
                raise PayloadError("Mach-O signature command is malformed")
            dataoff, datasize = struct.unpack_from("<II", prefix, offset + 8)
            signatures.append({"offset": offset, "dataoff": dataoff, "datasize": datasize})
            masks.append((offset + 12, 4))
        offset += command_size
    if offset != command_end or len(segments) != 1 or len(signatures) != 1:
        raise PayloadError("Mach-O signature or segment layout is unsupported")
    signature = signatures[0]
    if signature["offset"] + 16 != command_end:
        raise PayloadError("Mach-O signature command is not terminal")
    segment = segments[0]
    if (signature["datasize"] == 0 or signature["dataoff"] < command_end
            or signature["dataoff"] + signature["datasize"] != file_size
            or segment["fileoff"] + segment["filesize"] != file_size
            or signature["dataoff"] < segment["fileoff"]
            or signature["dataoff"] + signature["datasize"] > segment["fileoff"] + segment["filesize"]):
        raise PayloadError("Mach-O signature is not terminal or outside __LINKEDIT")
    nonempty_ranges = sorted((start, end) for start, end in all_segments if end > start)
    if any(right[0] < left[1] for left, right in zip(nonempty_ranges, nonempty_ranges[1:])):
        raise PayloadError("Mach-O segments overlap")
    masks.extend(((segment["offset"] + 32, 8), (segment["offset"] + 48, 8)))
    expected_vmsize = (segment["filesize"] + PAGE_SIZE_ARM64 - 1) & ~(PAGE_SIZE_ARM64 - 1)
    if segment["vmsize"] != expected_vmsize:
        raise PayloadError("Mach-O __LINKEDIT virtual size is not signature-aligned")
    return {"commands_end": command_end, "signature_offset": signature["dataoff"],
            "signature_size": signature["datasize"], "masks": masks,
            "linkedit_fileoff": segment["fileoff"], "linkedit_filesize": segment["filesize"],
            "linkedit_vmsize": segment["vmsize"]}


def _masked_equal(left: bytes, right: bytes, base: int, masks: list[tuple[int, int]]) -> bool:
    if len(left) != len(right):
        return False
    for start, length in masks:
        start -= base
        end = start + length
        left = left[:start] + bytes(length) + left[end:]
        right = right[:start] + bytes(length) + right[end:]
    return left == right


def _compare_file(source: BinaryIO, archive_size: int, framework_root: Path, relative: str) -> dict:
    try:
        descriptor = _open_framework_file(framework_root, relative)
        target = os.fdopen(descriptor, "rb")
    except OSError as error:
        raise PayloadError("framework member could not be opened safely") from error
    with target:
        target_stat = os.fstat(target.fileno())
        if not stat.S_ISREG(target_stat.st_mode) or target_stat.st_size > MAX_MEMBER_SIZE:
            raise PayloadError("framework member is not a supported regular file")
        if target_stat.st_size != archive_size:
            # Mach-O may legitimately change signature length.
            if not stat.S_ISREG(target_stat.st_mode):
                raise PayloadError("framework member is not a regular file")
        source_hash = hashlib.sha256()
        target_hash = hashlib.sha256()
        first_size = min(32, archive_size)
        target_first_size = min(32, target_stat.st_size)
        source_first = _read_exact(source, first_size) if first_size else b""
        target_first = _read_exact(target, target_first_size) if target_first_size else b""
        source_hash.update(source_first)
        target_hash.update(target_first)
        source_is_macho = source_first[:4] in MACHO_MAGICS
        target_is_macho = target_first[:4] in MACHO_MAGICS
        if source_is_macho != target_is_macho:
            raise PayloadError("Mach-O and non-Mach-O payloads differ")
        if source_is_macho:
            if len(source_first) < 32 or len(target_first) < 32:
                raise PayloadError("Mach-O header is truncated")
            source_command_size = struct.unpack_from("<I", source_first, 20)[0]
            target_command_size = struct.unpack_from("<I", target_first, 20)[0]
            if (source_command_size > MAX_LOAD_COMMAND_BYTES or target_command_size > MAX_LOAD_COMMAND_BYTES
                    or 32 + source_command_size > archive_size
                    or 32 + target_command_size > target_stat.st_size):
                raise PayloadError("Mach-O load command table is malformed")
            source_commands = _read_exact(source, source_command_size)
            target_commands = _read_exact(target, target_command_size)
            source_hash.update(source_commands)
            target_hash.update(target_commands)
            source_full = source_first + source_commands
            target_full = target_first + target_commands
        else:
            source_full = source_first
            target_full = target_first
        layout_source = _macho_layout(source_full, archive_size)
        layout_target = _macho_layout(target_full, target_stat.st_size)
        normalized = layout_source is not None or layout_target is not None
        if normalized and (layout_source is None or layout_target is None):
            raise PayloadError("Mach-O and non-Mach-O payloads differ")
        same = True
        if not normalized:
            same = (archive_size == target_stat.st_size and source_first == target_first)
            source_remaining = archive_size - first_size
            target_remaining = target_stat.st_size - target_first_size
            while source_remaining or target_remaining:
                source_amount = min(CHUNK_SIZE, source_remaining)
                target_amount = min(CHUNK_SIZE, target_remaining)
                left = _read_exact(source, source_amount) if source_amount else b""
                right = _read_exact(target, target_amount) if target_amount else b""
                source_hash.update(left)
                target_hash.update(right)
                same = same and left == right and len(left) == len(right)
                source_remaining -= source_amount
                target_remaining -= target_amount
        else:
            source_layout = layout_source
            target_layout = layout_target
            assert source_layout is not None and target_layout is not None
            same = (source_layout["signature_offset"] == target_layout["signature_offset"]
                    and source_layout["linkedit_fileoff"] == target_layout["linkedit_fileoff"]
                    and source_layout["commands_end"] == target_layout["commands_end"]
                    and _masked_equal(source_full, target_full, 0,
                                      source_layout["masks"])
                    and source_layout["linkedit_filesize"] == (
                        source_layout["signature_offset"] + source_layout["signature_size"]
                        - source_layout["linkedit_fileoff"])
                    and target_layout["linkedit_filesize"] == (
                        target_layout["signature_offset"] + target_layout["signature_size"]
                        - target_layout["linkedit_fileoff"])
                    and source_layout["linkedit_vmsize"] == (
                        (source_layout["linkedit_filesize"] + PAGE_SIZE_ARM64 - 1)
                        & ~(PAGE_SIZE_ARM64 - 1))
                    and target_layout["linkedit_vmsize"] == (
                        (target_layout["linkedit_filesize"] + PAGE_SIZE_ARM64 - 1)
                        & ~(PAGE_SIZE_ARM64 - 1)))
            source_prefix_left = source_layout["signature_offset"] - source_layout["commands_end"]
            target_prefix_left = target_layout["signature_offset"] - target_layout["commands_end"]
            if source_prefix_left != target_prefix_left:
                same = False
            remaining = source_prefix_left
            while remaining:
                amount = min(CHUNK_SIZE, remaining)
                left = _read_exact(source, amount)
                right = _read_exact(target, amount)
                source_hash.update(left)
                target_hash.update(right)
                same = same and left == right
                remaining -= amount
            # Signature blob is deliberately excluded from payload equality.
            for stream, digest, length in (
                (source, source_hash, source_layout["signature_size"]),
                (target, target_hash, target_layout["signature_size"]),
            ):
                remaining = length
                while remaining:
                    block = stream.read(min(CHUNK_SIZE, remaining))
                    if not block:
                        raise PayloadError("Mach-O signature blob is truncated")
                    digest.update(block)
                    remaining -= len(block)
            if source.read(1) or target.read(1):
                raise PayloadError("Mach-O signature is not terminal")
        if not normalized and target_stat.st_size != archive_size:
            same = False
        final_stat = os.fstat(target.fileno())
        if (final_stat.st_size != target_stat.st_size
                or final_stat.st_mtime_ns != target_stat.st_mtime_ns
                or final_stat.st_ctime_ns != target_stat.st_ctime_ns):
            raise PayloadError("framework member changed during comparison")
        return {"match": same, "normalization": "adhoc_macho_signature" if normalized else "exact",
                "archive_size": archive_size, "framework_size": target_stat.st_size,
                "archive_sha256": source_hash.hexdigest(), "framework_sha256": target_hash.hexdigest()}


def _read_archive_member(source: BinaryIO, entry: dict, framework_root: Path | None,
                         relative: str | None = None) -> dict:
    if framework_root is None:
        digest = hashlib.sha256()
        remaining = entry["size"]
        while remaining:
            block = source.read(min(CHUNK_SIZE, remaining))
            if not block:
                raise PayloadError("archive member is truncated")
            digest.update(block)
            remaining -= len(block)
        return {"match": False, "archive_sha256": digest.hexdigest(), "archive_size": entry["size"]}
    if relative is None:
        raise PayloadError("framework member path is unavailable")
    return _compare_file(source, entry["size"], framework_root, relative)


def compare_payload(archive: Path, framework: Path, pin: dict) -> dict:
    report = {
        "schema": 1,
        "archive_metadata_verified": False,
        "payload_match": False,
        "source_provenance_unverified": True,
        "signature_verification_not_performed": True,
        "archive_sha256": None,
        "members": [],
        "reason": None,
    }
    try:
        if not isinstance(pin, dict):
            raise PayloadError("pin is malformed")
        expected_hash = pin.get("sha256")
        if (not isinstance(expected_hash, str) or len(expected_hash) != 64
                or any(character not in "0123456789abcdefABCDEF" for character in expected_hash)):
            raise PayloadError("pin has invalid archive SHA-256")
        with _open_archive(archive) as source:
            initial_stat = _archive_stat(source)
            archive_size, archive_hash = _hash_file(source)
            report["archive_sha256"] = archive_hash
            _check_archive_unchanged(source, archive, initial_stat)
            if archive_hash != expected_hash.lower():
                raise PayloadError("archive SHA-256 does not match pin")
            selected, root = _archive_inventory(source)
            _check_archive_unchanged(source, archive, initial_stat)
            report["archive_metadata_verified"] = True
            framework_entries = _framework_inventory(framework)
            archive_paths = set(selected)
            framework_paths = set(framework_entries)
            results = []
            differences = []
            for path in sorted(archive_paths | framework_paths):
                archive_entry = selected.get(path)
                framework_entry = framework_entries.get(path)
                item = {"path": path}
                if archive_entry is None:
                    item.update({"status": "extra_framework_member", "framework_kind": framework_entry["kind"]})
                    if framework_entry["kind"] == "file":
                        item["framework_sha256"] = _hash_framework_file(framework, path)
                    elif framework_entry["kind"] == "symlink":
                        item["framework_target"] = framework_entry["link"]
                    differences.append(path)
                elif framework_entry is None:
                    item.update({"status": "missing_framework_member", "archive_kind": archive_entry["kind"]})
                    differences.append(path)
                elif archive_entry["kind"] != framework_entry["kind"]:
                    item.update({"status": "type_mismatch", "archive_kind": archive_entry["kind"],
                                 "framework_kind": framework_entry["kind"]})
                    if archive_entry["kind"] == "symlink":
                        item["archive_target"] = archive_entry["link"]
                    if framework_entry["kind"] == "symlink":
                        item["framework_target"] = framework_entry["link"]
                    if framework_entry["kind"] == "file":
                        item["framework_sha256"] = _hash_framework_file(framework, path)
                    differences.append(path)
                elif archive_entry["kind"] == "directory":
                    item["status"] = "match"
                elif archive_entry["kind"] == "symlink":
                    item.update({"status": "match" if archive_entry["link"] == framework_entry["link"] else "mismatch",
                                 "archive_target": archive_entry["link"],
                                 "framework_target": framework_entry["link"]})
                    if item["status"] != "match":
                        differences.append(path)
                else:
                    item["status"] = "pending"
                results.append(item)
            pending = {item["path"] for item in results if item["status"] == "pending"}
            missing_files = {path for path in differences if selected.get(path, {}).get("kind") == "file"}
            if pending or missing_files:
                source.seek(0)
                compressed = lzma.LZMAFile(source, "rb")
                try:
                    with tarfile.open(fileobj=compressed, mode="r|") as tar:
                        for member in tar:
                            name = _safe_archive_path(member.name)
                            if not name.startswith(root + "/"):
                                if member.isreg():
                                    stream = tar.extractfile(member)
                                    if stream is not None:
                                        stream.close()
                                continue
                            relative = name[len(root) + 1:]
                            if not member.isreg():
                                continue
                            stream = tar.extractfile(member)
                            if stream is None:
                                raise PayloadError("archive member data unavailable")
                            if relative in pending:
                                result = _read_archive_member(stream, selected[relative], framework, relative)
                                item = next(item for item in results if item["path"] == relative)
                                item.update({"status": "match" if result["match"] else "mismatch",
                                             "normalization": result["normalization"],
                                             "archive_sha256": result["archive_sha256"],
                                             "framework_sha256": result["framework_sha256"]})
                                if not result["match"]:
                                    differences.append(relative)
                            elif relative in missing_files:
                                result = _read_archive_member(stream, selected[relative], None)
                                item = next(item for item in results if item["path"] == relative)
                                item["archive_sha256"] = result["archive_sha256"]
                            else:
                                stream.close()
                finally:
                    compressed.close()
            _check_archive_unchanged(source, archive, initial_stat)
            report["members"] = results
            if differences:
                report["reason"] = "framework inventory or payload differs"
            else:
                report["payload_match"] = True
    except PayloadError as error:
        report["reason"] = str(error)
    except (OSError, tarfile.TarError, StopIteration):
        report["reason"] = "input unavailable or malformed"
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, default=Path("build/EngineCache/ArdiaCore-0fd438ac5e78.tar.xz"))
    parser.add_argument("--framework", type=Path,
                        default=Path("build/Arcusis Browser Candidate.app/Contents/Frameworks") / FRAMEWORK_NAME)
    parser.add_argument("--pin", type=Path, default=Path("ThirdParty/ArdiaCore/pin.json"))
    args = parser.parse_args(argv)
    try:
        pin = json.loads(args.pin.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        report = {"schema": 1, "archive_metadata_verified": False, "payload_match": False,
                  "source_provenance_unverified": True, "signature_verification_not_performed": True,
                  "archive_sha256": None, "members": [], "reason": "pin file unavailable or malformed"}
    else:
        report = compare_payload(args.archive, args.framework, pin)
    print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    return 0 if report["archive_metadata_verified"] and report["payload_match"] else 1


if __name__ == "__main__":
    sys.exit(main())
