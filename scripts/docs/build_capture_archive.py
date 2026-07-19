#!/usr/bin/env python3
"""Deterministically build and verify the anonymous collector snapshot.

The canonical source lives in ``collector/``.  The generated ZIP uses a fixed
``capture-scripts/`` prefix, fixed member metadata, and a generated internal
SHA-256 manifest.  Text line endings are normalized to LF so a Windows checkout
produces the same bytes as a POSIX checkout.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import os
import re
import stat
import tempfile
import zipfile
from pathlib import Path, PurePosixPath
from typing import Mapping, Sequence


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE_ROOT = REPOSITORY_ROOT / "collector"
DEFAULT_ARCHIVE = (
    REPOSITORY_ROOT / "docs" / "downloads" / "urban-wifi-capture-anonymous.zip"
)
DEFAULT_CHECKSUM = DEFAULT_ARCHIVE.with_suffix(".sha256")

ARCHIVE_PREFIX = "capture-scripts/"
INTERNAL_MANIFEST = "MANIFEST.sha256"
ARCHIVE_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
MAX_SOURCE_MEMBER_BYTES = 2 * 1024 * 1024

SOURCE_MEMBERS = (
    "CHANGELOG.md",
    "LICENSE",
    "MIGRATION.md",
    "PRIVACY.md",
    "PROVENANCE.md",
    "README.md",
    "SECURITY.md",
    "THIRD_PARTY_NOTICES.md",
    "code/start.py",
    "config.example.json",
    "docs/HARDWARE_TEST.md",
    "install.sh",
    "pyproject.toml",
    "requirements-build.txt",
    "requirements-unit.txt",
    "requirements.txt",
    "scripts/__init__.py",
    "scripts/install.sh",
    "scripts/urban-wifi-capture.sh",
    "src/urban_wifi_capture/__init__.py",
    "src/urban_wifi_capture/cli.py",
    "src/urban_wifi_capture/collector.py",
    "src/urban_wifi_capture/config.py",
    "src/urban_wifi_capture/database.py",
    "src/urban_wifi_capture/frames.py",
    "src/urban_wifi_capture/identifiers.py",
    "src/urban_wifi_capture/interfaces.py",
    "src/urban_wifi_capture/keys.py",
    "src/urban_wifi_capture/model.py",
    "systemd/urban-wifi-capture.service",
    "systemd/urban-wifi-interfaces.service",
    "tests/__init__.py",
    "tests/test_cli.py",
    "tests/test_collector.py",
    "tests/test_config.py",
    "tests/test_database.py",
    "tests/test_frames.py",
    "tests/test_identifiers.py",
    "tests/test_interfaces.py",
    "tests/test_keys.py",
    "tests/test_repository_security.py",
)

EXECUTABLE_MEMBERS = frozenset(
    {
        "code/start.py",
        "install.sh",
        "scripts/install.sh",
        "scripts/urban-wifi-capture.sh",
    }
)

AUTHOR_MARKERS = (
    b"juhyeon park",
    b"park, juhyeon",
    b"urbanjuhyeon",
    b"juhyeonpark.com",
)

SECRET_PATTERNS = (
    re.compile(rb"(?i)-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----"),
    re.compile(rb"(?<![A-Z0-9])AKIA[0-9A-Z]{16}(?![A-Z0-9])"),
    re.compile(rb"(?i)(?:github_pat_[a-z0-9_]{20,}|gh[opusr]_[a-z0-9_]{20,})"),
    re.compile(rb"AIza[0-9A-Za-z_-]{35}"),
    re.compile(rb"xox[baprs]-[0-9A-Za-z-]{20,}"),
    re.compile(rb"(?i)https?://[^/\s:@]{1,64}:[^/\s@]{4,}@"),
    re.compile(
        rb"(?i)(?<![a-z0-9_])"
        rb"(?:api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|"
        rb"password|passwd|private[_-]?key|deployment[_-]?key|release[_-]?key)"
        rb"(?![a-z0-9_-])\s*[\"']?\s*[:=]\s*[\"']?"
        rb"(?:[0-9a-f]{32,}|[a-z0-9+/=_-]{24,})"
    ),
)


class CaptureArchiveBuildError(RuntimeError):
    """Raised when source or generated artifacts violate the archive contract."""


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _safe_relative_name(name: str) -> PurePosixPath:
    path = PurePosixPath(name)
    if (
        not name
        or "\\" in name
        or path.is_absolute()
        or any(part in ("", ".", "..") for part in path.parts)
    ):
        raise CaptureArchiveBuildError(f"unsafe collector source member: {name!r}")
    return path


def _normalize_text_bytes(data: bytes, name: str) -> bytes:
    data = data.replace(b"\r\n", b"\n")
    if b"\r" in data:
        raise CaptureArchiveBuildError(
            f"collector source contains a non-CRLF carriage return: {name}"
        )
    if not data.endswith(b"\n"):
        raise CaptureArchiveBuildError(
            f"collector source must end with a line feed: {name}"
        )
    return data


def _scan_source_bytes(data: bytes, name: str) -> None:
    lowered = data.lower()
    if any(marker in lowered for marker in AUTHOR_MARKERS):
        raise CaptureArchiveBuildError(
            f"collector source contains an author-identifying marker: {name}"
        )
    if any(pattern.search(data) for pattern in SECRET_PATTERNS):
        raise CaptureArchiveBuildError(
            f"collector source contains credential-like material: {name}"
        )


def read_source_tree(source_root: Path = DEFAULT_SOURCE_ROOT) -> dict[str, bytes]:
    source_root = Path(source_root)
    if not source_root.is_dir() or source_root.is_symlink():
        raise CaptureArchiveBuildError(
            f"collector source root is missing or unsafe: {source_root}"
        )

    actual: set[str] = set()
    for path in source_root.rglob("*"):
        if path.is_symlink():
            raise CaptureArchiveBuildError(
                f"collector source contains a symlink: {path}"
            )
        if path.is_file():
            actual.add(path.relative_to(source_root).as_posix())

    expected = set(SOURCE_MEMBERS)
    if actual != expected:
        missing = sorted(expected - actual)
        unexpected = sorted(actual - expected)
        raise CaptureArchiveBuildError(
            "collector source member set differs from the allowlist; "
            f"missing={missing!r}, unexpected={unexpected!r}"
        )

    payload: dict[str, bytes] = {}
    for name in SOURCE_MEMBERS:
        relative = _safe_relative_name(name)
        path = source_root.joinpath(*relative.parts)
        data = path.read_bytes()
        if not data or len(data) > MAX_SOURCE_MEMBER_BYTES:
            raise CaptureArchiveBuildError(
                f"collector source size is outside the contract: {name}"
            )
        data = _normalize_text_bytes(data, name)
        _scan_source_bytes(data, name)
        payload[name] = data
    return payload


def build_internal_manifest(payload: Mapping[str, bytes]) -> bytes:
    if tuple(payload) != SOURCE_MEMBERS:
        raise CaptureArchiveBuildError("collector payload order differs from the allowlist")
    return "".join(
        f"{sha256_bytes(payload[name])}  {name}\n" for name in SOURCE_MEMBERS
    ).encode("ascii")


def _zip_info(name: str, mode: int) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, ARCHIVE_TIMESTAMP)
    info.create_system = 3
    info.create_version = 20
    info.extract_version = 20
    info.compress_type = zipfile.ZIP_STORED
    info.external_attr = (stat.S_IFREG | mode) << 16
    info.internal_attr = 0
    info.extra = b""
    info.comment = b""
    return info


def build_archive_bytes(source_root: Path = DEFAULT_SOURCE_ROOT) -> bytes:
    payload = read_source_tree(source_root)
    manifest = build_internal_manifest(payload)
    output = io.BytesIO()
    with zipfile.ZipFile(
        output, "w", compression=zipfile.ZIP_STORED, allowZip64=True
    ) as archive:
        for name in SOURCE_MEMBERS:
            mode = 0o755 if name in EXECUTABLE_MEMBERS else 0o644
            archive.writestr(
                _zip_info(f"{ARCHIVE_PREFIX}{name}", mode), payload[name]
            )
        archive.writestr(
            _zip_info(f"{ARCHIVE_PREFIX}{INTERNAL_MANIFEST}", 0o644), manifest
        )
    return output.getvalue()


def checksum_bytes(archive_bytes: bytes, archive_name: str) -> bytes:
    if Path(archive_name).name != archive_name:
        raise CaptureArchiveBuildError("archive checksum name must be a basename")
    return f"{sha256_bytes(archive_bytes)}  {archive_name}\n".encode("ascii")


def expected_artifacts(
    source_root: Path = DEFAULT_SOURCE_ROOT,
    archive_name: str = DEFAULT_ARCHIVE.name,
) -> tuple[bytes, bytes]:
    first = build_archive_bytes(source_root)
    second = build_archive_bytes(source_root)
    if first != second:
        raise CaptureArchiveBuildError("collector archive build is not deterministic")
    return first, checksum_bytes(first, archive_name)


def check_artifacts(
    source_root: Path = DEFAULT_SOURCE_ROOT,
    archive_path: Path = DEFAULT_ARCHIVE,
    checksum_path: Path = DEFAULT_CHECKSUM,
) -> str:
    archive_path = Path(archive_path)
    checksum_path = Path(checksum_path)
    expected_archive, expected_checksum = expected_artifacts(
        source_root, archive_path.name
    )
    try:
        actual_archive = archive_path.read_bytes()
        actual_checksum = checksum_path.read_bytes()
    except OSError as exc:
        raise CaptureArchiveBuildError(
            "collector archive or checksum is missing/unreadable"
        ) from exc
    if actual_archive != expected_archive:
        raise CaptureArchiveBuildError(
            "collector archive differs from a deterministic source rebuild"
        )
    if actual_checksum != expected_checksum:
        raise CaptureArchiveBuildError(
            "collector checksum differs from the deterministic source rebuild"
        )
    return sha256_bytes(expected_archive)


def _atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def write_artifacts(
    source_root: Path = DEFAULT_SOURCE_ROOT,
    archive_path: Path = DEFAULT_ARCHIVE,
    checksum_path: Path = DEFAULT_CHECKSUM,
) -> str:
    archive_path = Path(archive_path)
    checksum_path = Path(checksum_path)
    archive_bytes, checksum = expected_artifacts(source_root, archive_path.name)
    _atomic_write(archive_path, archive_bytes)
    _atomic_write(checksum_path, checksum)
    return sha256_bytes(archive_bytes)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build or verify the deterministic anonymous collector ZIP"
    )
    parser.add_argument("--check", action="store_true", help="verify committed artifacts")
    parser.add_argument("--source-root", type=Path, default=DEFAULT_SOURCE_ROOT)
    parser.add_argument("--archive", type=Path, default=DEFAULT_ARCHIVE)
    parser.add_argument("--checksum", type=Path, default=DEFAULT_CHECKSUM)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    options = parse_args(argv)
    try:
        if options.check:
            digest = check_artifacts(
                options.source_root, options.archive, options.checksum
            )
            action = "verified"
        else:
            digest = write_artifacts(
                options.source_root, options.archive, options.checksum
            )
            action = "built"
    except CaptureArchiveBuildError as exc:
        raise SystemExit(f"error: {exc}") from exc
    print(f"collector archive {action}: {digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
