#!/usr/bin/env python3
"""Generate a private 32-byte key for release-specific re-pseudonymization.

The key is an author-side build secret. It must never be committed, archived
with the public data, printed, or passed on a command line as a value.
"""

from __future__ import annotations

import argparse
import os
import secrets
import stat
from pathlib import Path

KEY_BYTES = 32


class KeyGenerationError(RuntimeError):
    """Raised when a key cannot be created without an unsafe filesystem action."""


def _is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def _reject_symlink_components(path: Path) -> None:
    current = path.parent
    while True:
        if current.exists() and current.is_symlink():
            raise KeyGenerationError(f"refusing symlinked parent: {current}")
        if current == current.parent:
            return
        current = current.parent


def generate_key(output: Path, repository_root: Path) -> Path:
    # Keep the caller's lexical path long enough to detect a symlinked parent.
    # ``Path.resolve()`` here would silently follow that parent before the check.
    output = Path(os.path.abspath(os.fspath(output.expanduser())))
    repository_root = repository_root.resolve(strict=True)
    if output.exists() or output.is_symlink():
        raise KeyGenerationError(f"refusing to overwrite existing path: {output}")
    _reject_symlink_components(output)

    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    _reject_symlink_components(output)
    output = output.parent.resolve(strict=True) / output.name
    if _is_within(output, repository_root):
        raise KeyGenerationError("release keys must be stored outside the repository")

    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(output, flags, 0o600)
    try:
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            descriptor = -1
            written = handle.write(secrets.token_bytes(KEY_BYTES))
            if written != KEY_BYTES:
                raise KeyGenerationError("short key write")
            handle.flush()
            os.fsync(handle.fileno())
    except Exception:
        output.unlink(missing_ok=True)
        raise
    finally:
        if descriptor >= 0:
            os.close(descriptor)

    try:
        output.chmod(stat.S_IRUSR | stat.S_IWUSR)
    except OSError as exc:
        output.unlink(missing_ok=True)
        raise KeyGenerationError("could not set owner-only key permissions") from exc
    if output.stat().st_size != KEY_BYTES:
        output.unlink(missing_ok=True)
        raise KeyGenerationError("generated key has an invalid length")
    return output


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate an author-side 32-byte public-release build key."
    )
    parser.add_argument("--output", required=True, type=Path)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    repository_root = Path(__file__).resolve().parents[2]
    try:
        output = generate_key(args.output, repository_root)
    except (KeyGenerationError, OSError) as exc:
        raise SystemExit(f"error: {exc}") from exc
    print(f"created private {KEY_BYTES}-byte release key: {output}")
    print("Do not commit, upload, archive with the dataset, or print this file.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
