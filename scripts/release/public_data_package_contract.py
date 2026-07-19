#!/usr/bin/env python3
"""Shared fail-closed contract for the public-data package and ZIP archive."""

from __future__ import annotations

import hashlib
import os
import re
from pathlib import Path


PACKAGE_VERSION = "historical-v4-public-package-candidate-1"
PACKAGE_ROOT_RELATIVE = Path("tmp") / "public-data-package"
MANIFEST_FILENAME = "MANIFEST.sha256"
ALLOWED_PACKAGE_FILENAMES = frozenset(
    {
        "DATA_DICTIONARY.md",
        MANIFEST_FILENAME,
        "README.md",
        "SOURCE_EVIDENCE.csv",
        "build_report.md",
        "public_handoff_manifest.csv",
        "sensor_coordinates.csv",
        "verification_checks.csv",
        "verification_report.md",
        "wifi_unist19_20sec.parquet",
        "wifi_uou20_20sec.parquet",
    }
)
MANIFEST_ENTRY_FILENAMES = ALLOWED_PACKAGE_FILENAMES - {MANIFEST_FILENAME}
SAFE_BASENAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
MANIFEST_LINE = re.compile(r"^([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9_.-]*)$")


class PackageContractError(RuntimeError):
    """Raised when a package or archive falls outside the fixed contract."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def package_root(repository_root: Path, *, must_exist: bool = True) -> Path:
    repository_root = repository_root.resolve(strict=True)
    lexical_root = repository_root / PACKAGE_ROOT_RELATIVE
    root = lexical_root.resolve(strict=must_exist)
    if not is_within(root, repository_root):
        raise PackageContractError(
            "tmp/public-data-package must resolve inside the repository"
        )
    return root


def resolve_package_dir(package: Path, repository_root: Path) -> Path:
    root = package_root(repository_root)
    lexical = Path(os.path.abspath(os.fspath(package)))
    if lexical.is_symlink():
        raise PackageContractError("refusing a symlinked package directory")
    resolved = lexical.resolve(strict=True)
    if not resolved.is_dir() or not is_within(resolved, root):
        raise PackageContractError(
            "package must remain under tmp/public-data-package"
        )
    return resolved


def package_files(package: Path) -> dict[str, Path]:
    directories = sorted(path for path in package.rglob("*") if path.is_dir())
    if directories:
        raise PackageContractError("package contains an unexpected subdirectory")
    files = sorted(path for path in package.rglob("*") if path.is_file())
    if any(path.is_symlink() for path in files):
        raise PackageContractError("package contains a symbolic-link file")
    if any(path.parent != package for path in files):
        raise PackageContractError("package files must be at the archive root")
    names = [path.name for path in files]
    if len(names) != len(set(names)) or set(names) != ALLOWED_PACKAGE_FILENAMES:
        raise PackageContractError("package file allowlist mismatch")
    return {path.name: path for path in files}


def parse_sha256_manifest(path: Path) -> dict[str, str]:
    try:
        text = path.read_text(encoding="ascii")
    except UnicodeDecodeError as exc:
        raise PackageContractError("SHA-256 manifest must be ASCII") from exc
    if not text.endswith("\n") or "\r" in text:
        raise PackageContractError("SHA-256 manifest must use final-LF line endings")
    entries: dict[str, str] = {}
    lines = text.splitlines()
    filenames_in_order: list[str] = []
    for line in lines:
        match = MANIFEST_LINE.fullmatch(line)
        if match is None:
            raise PackageContractError("SHA-256 manifest has an invalid line")
        digest, filename = match.groups()
        if filename in entries:
            raise PackageContractError("SHA-256 manifest has a duplicate filename")
        entries[filename] = digest
        filenames_in_order.append(filename)
    if filenames_in_order != sorted(filenames_in_order):
        raise PackageContractError(
            "SHA-256 manifest entries must be sorted by filename"
        )
    if set(entries) != MANIFEST_ENTRY_FILENAMES:
        raise PackageContractError("SHA-256 manifest file allowlist mismatch")
    return entries


def verify_package_hashes(package: Path) -> dict[str, str]:
    files = package_files(package)
    entries = parse_sha256_manifest(files[MANIFEST_FILENAME])
    for filename, expected in entries.items():
        if sha256_file(files[filename]) != expected:
            raise PackageContractError(
                f"SHA-256 mismatch for allowlisted file: {filename}"
            )
    return entries
