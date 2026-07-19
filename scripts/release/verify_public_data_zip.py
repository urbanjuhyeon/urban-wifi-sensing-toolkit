#!/usr/bin/env python3
"""Verify deterministic ZIP metadata and byte equality with the package folder."""

from __future__ import annotations

import argparse
import hashlib
import os
import zipfile
from pathlib import Path

from build_public_data_zip import ZIP_TIMESTAMP, ZIP_UNIX_MODE
from public_data_package_contract import (
    ALLOWED_PACKAGE_FILENAMES,
    PACKAGE_VERSION,
    PackageContractError,
    is_within,
    package_files,
    package_root,
    resolve_package_dir,
    sha256_file,
    verify_package_hashes,
)


def _resolve_archive(archive: Path, repository_root: Path) -> Path:
    root = package_root(repository_root)
    lexical = Path(os.path.abspath(os.fspath(archive)))
    if lexical.is_symlink():
        raise PackageContractError("refusing a symlinked ZIP archive")
    resolved = lexical.resolve(strict=True)
    if not resolved.is_file() or resolved.parent != root or not is_within(
        resolved, root
    ):
        raise PackageContractError(
            "ZIP archive must be a direct child of tmp/public-data-package"
        )
    return resolved


def verify_deterministic_zip(
    package: Path, archive: Path, repository_root: Path
) -> tuple[str, int]:
    package = resolve_package_dir(package, repository_root)
    files = package_files(package)
    verify_package_hashes(package)
    archive = _resolve_archive(archive, repository_root)

    with zipfile.ZipFile(archive, mode="r", allowZip64=True) as zipped:
        infos = zipped.infolist()
        names = [info.filename for info in infos]
        if names != sorted(ALLOWED_PACKAGE_FILENAMES):
            raise PackageContractError("ZIP entry allowlist or ordering mismatch")
        if len(names) != len(set(names)):
            raise PackageContractError("ZIP contains duplicate entry names")
        if zipped.testzip() is not None:
            raise PackageContractError("ZIP CRC verification failed")

        for info in infos:
            if (
                info.is_dir()
                or Path(info.filename).name != info.filename
                or info.date_time != ZIP_TIMESTAMP
                or info.compress_type != zipfile.ZIP_STORED
                or info.flag_bits & 0x1
                or info.create_system != 3
                or (info.external_attr >> 16) != ZIP_UNIX_MODE
            ):
                raise PackageContractError(
                    f"ZIP metadata contract failed for: {info.filename}"
                )
            expected_path = files[info.filename]
            if info.file_size != expected_path.stat().st_size:
                raise PackageContractError(
                    f"ZIP size differs from package file: {info.filename}"
                )
            digest = hashlib.sha256()
            with zipped.open(info, mode="r") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
            if digest.hexdigest() != sha256_file(expected_path):
                raise PackageContractError(
                    f"ZIP content differs from package file: {info.filename}"
                )

    return sha256_file(archive), archive.stat().st_size


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
    archive = args.archive or (
        repository_root / "tmp" / "public-data-package" / f"{PACKAGE_VERSION}.zip"
    )
    try:
        digest, size = verify_deterministic_zip(
            package, archive, repository_root
        )
    except (OSError, PackageContractError, zipfile.BadZipFile) as exc:
        raise SystemExit(f"error: {exc}") from exc
    print(
        "Deterministic public-data ZIP verified: "
        f"{len(ALLOWED_PACKAGE_FILENAMES)} entries, {size} bytes, SHA-256 {digest}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
