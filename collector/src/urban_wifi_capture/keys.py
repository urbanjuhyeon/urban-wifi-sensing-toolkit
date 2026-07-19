"""Fail-closed deployment pseudonymization-key file handling."""

from __future__ import annotations

import os
import secrets
import stat
from pathlib import Path

PSEUDONYMIZATION_KEY_BYTES = 32


class KeyFileError(PermissionError):
    """Raised when a key file cannot be used without weakening its boundary."""


def _absolute_without_following(path: Path) -> Path:
    """Normalize dot segments without resolving a symlinked final component."""

    return Path(path).expanduser().absolute()


def _reject_symlinked_components(path: Path) -> None:
    for candidate in (path, *path.parents):
        try:
            details = candidate.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(details.st_mode):
            raise KeyFileError(f"pseudonymization key path contains a symlink: {candidate}")


def load_pseudonymization_key(path: Path) -> bytes:
    """Read one owned, private, regular file containing exactly 32 raw bytes."""

    absolute = _absolute_without_following(path)
    _reject_symlinked_components(absolute)
    try:
        before = absolute.lstat()
    except FileNotFoundError as exc:
        raise KeyFileError(f"pseudonymization key file does not exist: {absolute}") from exc
    except OSError as exc:
        raise KeyFileError(f"cannot inspect pseudonymization key file: {absolute}") from exc

    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise KeyFileError("pseudonymization key must be a single regular file")
    if os.name == "posix":
        mode = stat.S_IMODE(before.st_mode)
        private_owner_file = before.st_uid == os.geteuid() and mode == 0o600
        readable_groups = {os.getegid(), *os.getgroups()}
        root_managed_service_file = (
            before.st_uid == 0 and before.st_gid in readable_groups and mode == 0o640
        )
        if not (private_owner_file or root_managed_service_file):
            raise KeyFileError(
                "pseudonymization key must be owner mode 0600, or root-owned mode 0640 "
                "with a readable service group"
            )

    flags = os.O_RDONLY
    if hasattr(os, "O_BINARY"):
        flags |= os.O_BINARY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(absolute, flags)
    except OSError as exc:
        raise KeyFileError(f"cannot open pseudonymization key file: {absolute}") from exc
    try:
        after = os.fstat(descriptor)
        if (
            not stat.S_ISREG(after.st_mode)
            or after.st_nlink != 1
            or (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino)
        ):
            raise KeyFileError("pseudonymization key changed during validation")
        payload = bytearray()
        while len(payload) <= PSEUDONYMIZATION_KEY_BYTES:
            chunk = os.read(descriptor, PSEUDONYMIZATION_KEY_BYTES + 1 - len(payload))
            if not chunk:
                break
            payload.extend(chunk)
    finally:
        os.close(descriptor)

    if len(payload) != PSEUDONYMIZATION_KEY_BYTES:
        raise KeyFileError(
            "pseudonymization key file must contain exactly 32 raw bytes "
            "with no text encoding or newline"
        )
    return bytes(payload)


def generate_pseudonymization_key(path: Path) -> Path:
    """Atomically create a private 32-byte CSPRNG key without overwriting."""

    absolute = _absolute_without_following(path)
    _reject_symlinked_components(absolute)
    try:
        parent = absolute.parent.lstat()
    except FileNotFoundError as exc:
        raise KeyFileError(f"key parent directory does not exist: {absolute.parent}") from exc
    if not stat.S_ISDIR(parent.st_mode):
        raise KeyFileError(f"key parent path is not a directory: {absolute.parent}")

    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_BINARY"):
        flags |= os.O_BINARY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(absolute, flags, 0o600)
    except FileExistsError as exc:
        raise KeyFileError(f"refusing to overwrite existing key path: {absolute}") from exc
    except OSError as exc:
        raise KeyFileError(f"cannot create pseudonymization key file: {absolute}") from exc

    created = True
    created_details = os.fstat(descriptor)
    try:
        payload = secrets.token_bytes(PSEUDONYMIZATION_KEY_BYTES)
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OSError("short write while creating pseudonymization key")
            view = view[written:]
        os.fsync(descriptor)
        if os.name == "posix":
            os.fchmod(descriptor, 0o600)
        created = False
    finally:
        os.close(descriptor)
        if created:
            try:
                current = absolute.lstat()
                if (current.st_dev, current.st_ino) == (
                    created_details.st_dev,
                    created_details.st_ino,
                ):
                    absolute.unlink()
            except OSError:
                pass
    return absolute
