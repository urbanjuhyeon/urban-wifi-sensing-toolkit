#!/usr/bin/env python3
"""Fail closed if a public-handoff candidate contains release secrets.

The scanner reports only the affected filename and pattern class. It never
prints a key, an identifier, or a matching data fragment.
"""

from __future__ import annotations

import argparse
import os
import re
from pathlib import Path
from typing import Iterable


KEY_BYTES = 32
CHUNK_BYTES = 1024 * 1024
ALLOWED_FILENAMES = {
    "build_report.md",
    "public_handoff_manifest.csv",
    "verification_checks.csv",
    "verification_report.md",
    "wifi_unist19_20sec_public-candidate.parquet",
    "wifi_uou20_20sec_public-candidate.parquet",
}
FORBIDDEN_MAPPING_MARKERS = (
    b"internal_source_address",
    b"public_source_address",
)
RAW_MAC_PATTERN = re.compile(
    rb"(?i)(?<![0-9a-f])(?:[0-9a-f]{2}:){5}[0-9a-f]{2}(?![0-9a-f])"
)


class SecretScanError(RuntimeError):
    """Raised when a candidate is outside the safe public-handoff contract."""


def _is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def _read_key(path: Path, repository_root: Path) -> bytes:
    lexical = Path(os.path.abspath(os.fspath(path.expanduser())))
    if lexical.is_symlink():
        raise SecretScanError("refusing a symlinked key file")
    resolved = lexical.resolve(strict=True)
    if _is_within(resolved, repository_root):
        raise SecretScanError("key files must remain outside the repository")
    if not resolved.is_file() or resolved.stat().st_size != KEY_BYTES:
        raise SecretScanError("each key file must contain exactly 32 raw bytes")
    return resolved.read_bytes()


def _iter_chunks(path: Path, overlap: int) -> Iterable[bytes]:
    carry = b""
    with path.open("rb") as handle:
        while chunk := handle.read(CHUNK_BYTES):
            data = carry + chunk
            yield data
            carry = data[-overlap:] if overlap else b""


def _scan_file(path: Path, secret_patterns: tuple[bytes, ...]) -> list[str]:
    findings: set[str] = set()
    max_pattern = max(
        [len(pattern) for pattern in secret_patterns + FORBIDDEN_MAPPING_MARKERS]
        + [17]
    )
    for chunk in _iter_chunks(path, overlap=max_pattern - 1):
        if any(pattern in chunk for pattern in secret_patterns):
            findings.add("release-key material or path")
        if any(marker in chunk for marker in FORBIDDEN_MAPPING_MARKERS):
            findings.add("private identifier-mapping field")
        if RAW_MAC_PATTERN.search(chunk):
            findings.add("colon-delimited MAC-like value")
    return sorted(findings)


def scan_candidate(
    candidate: Path, key_files: Iterable[Path], repository_root: Path
) -> tuple[int, int]:
    repository_root = repository_root.resolve(strict=True)
    allowed_root = (repository_root / "tmp" / "public-release-handoff").resolve(
        strict=True
    )
    candidate = candidate.resolve(strict=True)
    if not candidate.is_dir() or not _is_within(candidate, allowed_root):
        raise SecretScanError(
            "candidate must remain under tmp/public-release-handoff"
        )

    keys = tuple(_read_key(path, repository_root) for path in key_files)
    if len(keys) != 2 or keys[0] == keys[1]:
        raise SecretScanError("exactly two distinct release key files are required")

    files = sorted(path for path in candidate.rglob("*") if path.is_file())
    directories = sorted(path for path in candidate.rglob("*") if path.is_dir())
    if directories:
        raise SecretScanError("candidate contains an unexpected subdirectory")
    names = {path.name for path in files}
    if names != ALLOWED_FILENAMES or len(files) != len(ALLOWED_FILENAMES):
        raise SecretScanError("candidate file allowlist mismatch")

    secret_patterns: list[bytes] = []
    for key, key_path in zip(keys, key_files, strict=True):
        secret_patterns.extend(
            (
                key,
                key.hex().encode("ascii"),
                key.hex().upper().encode("ascii"),
                str(key_path.resolve(strict=True)).encode("utf-8"),
                str(key_path.resolve(strict=True)).encode("utf-16le"),
            )
        )

    findings: list[str] = []
    for path in files:
        for category in _scan_file(path, tuple(secret_patterns)):
            findings.append(f"{path.name}: {category}")
    if findings:
        raise SecretScanError("; ".join(findings))
    return len(files), sum(path.stat().st_size for path in files)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Scan a public-handoff candidate without printing secrets."
    )
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument(
        "--key-file", required=True, action="append", type=Path, dest="key_files"
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    repository_root = Path(__file__).resolve().parents[2]
    try:
        file_count, total_bytes = scan_candidate(
            args.candidate, args.key_files, repository_root
        )
    except (OSError, SecretScanError) as exc:
        raise SystemExit(f"error: {exc}") from exc
    print(
        "Public-handoff secret scan passed: "
        f"{file_count} allowlisted files ({total_bytes} bytes)."
    )
    print("No key material, key path, mapping field, or raw MAC-like value was found.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
