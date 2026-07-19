#!/usr/bin/env python3
"""Build a deterministic, top-level-only ZIP from a verified package folder."""

from __future__ import annotations

import argparse
import os
import shutil
import zipfile
from pathlib import Path

from public_data_package_contract import (
    PACKAGE_VERSION,
    PackageContractError,
    is_within,
    package_files,
    package_root,
    resolve_package_dir,
    verify_package_hashes,
)


ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
ZIP_UNIX_MODE = 0o100644
COPY_BUFFER_BYTES = 1024 * 1024


def _resolve_output(output: Path, repository_root: Path) -> Path:
    root = package_root(repository_root)
    lexical = Path(os.path.abspath(os.fspath(output)))
    parent = lexical.parent.resolve(strict=True)
    if parent != root or not is_within(lexical, root):
        raise PackageContractError(
            "ZIP output must be a direct child of tmp/public-data-package"
        )
    if lexical.suffix.lower() != ".zip":
        raise PackageContractError("ZIP output must end in .zip")
    if lexical.exists() or lexical.is_symlink():
        raise PackageContractError("refusing to overwrite an existing ZIP")
    return lexical


def build_deterministic_zip(
    package: Path, output: Path, repository_root: Path
) -> Path:
    package = resolve_package_dir(package, repository_root)
    files = package_files(package)
    verify_package_hashes(package)
    output = _resolve_output(output, repository_root)
    temporary = output.with_name(f".{output.name}.building-{os.getpid()}")
    if temporary.exists() or temporary.is_symlink():
        raise PackageContractError("refusing an existing ZIP staging path")

    try:
        with zipfile.ZipFile(
            temporary,
            mode="x",
            compression=zipfile.ZIP_STORED,
            allowZip64=True,
            strict_timestamps=True,
        ) as archive:
            for filename in sorted(files):
                info = zipfile.ZipInfo(filename=filename, date_time=ZIP_TIMESTAMP)
                info.compress_type = zipfile.ZIP_STORED
                info.create_system = 3
                info.external_attr = ZIP_UNIX_MODE << 16
                info.internal_attr = 0
                info.flag_bits = 0
                with files[filename].open("rb") as source, archive.open(
                    info, mode="w", force_zip64=True
                ) as destination:
                    shutil.copyfileobj(source, destination, COPY_BUFFER_BYTES)
        if output.exists() or output.is_symlink():
            raise PackageContractError("ZIP output appeared during build")
        os.rename(temporary, output)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise
    return output


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path)
    parser.add_argument("--output", type=Path)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    repository_root = Path(__file__).resolve().parents[2]
    package = args.package or (
        repository_root / "tmp" / "public-data-package" / PACKAGE_VERSION
    )
    output = args.output or (
        repository_root / "tmp" / "public-data-package" / f"{PACKAGE_VERSION}.zip"
    )
    try:
        result = build_deterministic_zip(package, output, repository_root)
    except (OSError, PackageContractError, zipfile.BadZipFile) as exc:
        raise SystemExit(f"error: {exc}") from exc
    print(f"Built deterministic public-data ZIP: {result.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
