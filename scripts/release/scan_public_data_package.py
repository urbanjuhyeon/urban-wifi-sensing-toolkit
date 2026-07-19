#!/usr/bin/env python3
"""Keyless structural scan for secrets, raw MACs, and mapping fields."""

from __future__ import annotations

import argparse
import re
import zipfile
from pathlib import Path
from typing import Iterable

from public_data_package_contract import (
    PACKAGE_VERSION,
    PackageContractError,
    package_files,
    resolve_package_dir,
    verify_package_hashes,
)
from verify_public_data_zip import verify_deterministic_zip


CHUNK_BYTES = 1024 * 1024
FORBIDDEN_MARKERS = {
    "private identifier-mapping field": (
        b"internal_source_address",
        b"public_source_address",
        b"mapping_file",
        b"mapping_path",
    ),
    "release-key field or file marker": (
        b"key_file",
        b"key_path",
        b"key_hex",
        b"secret_key",
        b"private_key",
        b"release.key",
    ),
    "raw capture field": (
        b"raw_mac_address",
        b"destination_address",
        b"frame_bytes",
        b"packet_bytes",
        b"bssid",
        b"ssid",
    ),
}
RAW_MAC_PATTERN = re.compile(
    rb"(?i)(?<![0-9a-f])(?:[0-9a-f]{2}:){5}[0-9a-f]{2}(?![0-9a-f])"
)


class PackageScanError(RuntimeError):
    """Raised when public package bytes contain a forbidden finding class."""


def _iter_stream_chunks(handle, overlap: int) -> Iterable[bytes]:
    carry = b""
    while chunk := handle.read(CHUNK_BYTES):
        data = carry + chunk
        yield data
        carry = data[-overlap:] if overlap else b""


def _scan_stream(handle) -> list[str]:
    findings: set[str] = set()
    longest = max(
        [len(marker) for markers in FORBIDDEN_MARKERS.values() for marker in markers]
        + [17]
    )
    for chunk in _iter_stream_chunks(handle, overlap=longest - 1):
        lowered = chunk.lower()
        for category, markers in FORBIDDEN_MARKERS.items():
            if any(marker in lowered for marker in markers):
                findings.add(category)
        if RAW_MAC_PATTERN.search(chunk):
            findings.add("colon-delimited MAC-like value")
    return sorted(findings)


def scan_package(
    package: Path, repository_root: Path, archive: Path | None = None
) -> tuple[int, int]:
    package = resolve_package_dir(package, repository_root)
    files = package_files(package)
    verify_package_hashes(package)

    findings: list[str] = []
    total_bytes = 0
    for filename in sorted(files):
        path = files[filename]
        total_bytes += path.stat().st_size
        with path.open("rb") as handle:
            findings.extend(
                f"{filename}: {category}" for category in _scan_stream(handle)
            )

    if archive is not None:
        verify_deterministic_zip(package, archive, repository_root)
        with zipfile.ZipFile(archive, mode="r") as zipped:
            for info in zipped.infolist():
                with zipped.open(info, mode="r") as handle:
                    findings.extend(
                        f"ZIP/{info.filename}: {category}"
                        for category in _scan_stream(handle)
                    )

    if findings:
        raise PackageScanError("; ".join(sorted(set(findings))))
    return len(files), total_bytes


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path)
    parser.add_argument("--archive", type=Path)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    repository_root = Path(__file__).resolve().parents[2]
    package = args.package or (
        repository_root / "tmp" / "public-data-package" / PACKAGE_VERSION
    )
    try:
        file_count, total_bytes = scan_package(
            package, repository_root, args.archive
        )
    except (OSError, PackageContractError, PackageScanError, zipfile.BadZipFile) as exc:
        raise SystemExit(f"error: {exc}") from exc
    print(
        "Public-data package structural scan passed: "
        f"{file_count} allowlisted files ({total_bytes} bytes)."
    )
    print(
        "No release-key field/file marker, private mapping field, raw capture "
        "field, or colon-delimited MAC-like value was found."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
