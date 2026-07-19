from __future__ import annotations

import hashlib
import hmac
import importlib.util
import os
import stat
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
GENERATOR_PATH = REPOSITORY_ROOT / "scripts" / "release" / "generate_release_key.py"
SPEC = importlib.util.spec_from_file_location("generate_release_key", GENERATOR_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load release-key generator: {GENERATOR_PATH}")
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


class ReleaseKeyTest(unittest.TestCase):
    def test_generates_distinct_exact_32_byte_keys_outside_repository(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = GENERATOR.generate_key(root / "first.key", REPOSITORY_ROOT)
            second = GENERATOR.generate_key(root / "second.key", REPOSITORY_ROOT)

            self.assertEqual(first.stat().st_size, GENERATOR.KEY_BYTES)
            self.assertEqual(second.stat().st_size, GENERATOR.KEY_BYTES)
            self.assertNotEqual(first.read_bytes(), second.read_bytes())
            if os.name != "nt":
                self.assertEqual(stat.S_IMODE(first.stat().st_mode), 0o600)

    def test_refuses_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "release.key"
            GENERATOR.generate_key(output, REPOSITORY_ROOT)
            original = output.read_bytes()
            with self.assertRaisesRegex(GENERATOR.KeyGenerationError, "overwrite"):
                GENERATOR.generate_key(output, REPOSITORY_ROOT)
            self.assertEqual(output.read_bytes(), original)

    def test_refuses_repository_destination(self) -> None:
        with tempfile.TemporaryDirectory(dir=REPOSITORY_ROOT / "tmp") as temporary:
            output = Path(temporary) / "must-not-exist.key"
            with self.assertRaisesRegex(
                GENERATOR.KeyGenerationError, "outside the repository"
            ):
                GENERATOR.generate_key(output, REPOSITORY_ROOT)
            self.assertFalse(output.exists())

    def test_refuses_symlinked_parent_when_platform_allows_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            real_parent = root / "real"
            real_parent.mkdir()
            linked_parent = root / "linked"
            try:
                linked_parent.symlink_to(real_parent, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"directory symlinks unavailable: {exc}")
            with self.assertRaisesRegex(GENERATOR.KeyGenerationError, "symlinked"):
                GENERATOR.generate_key(linked_parent / "release.key", REPOSITORY_ROOT)
            self.assertFalse((real_parent / "release.key").exists())

    def test_fixed_release_hmac_vector(self) -> None:
        key = b"01234567890123456789012345678901"
        message = (
            b"urban-wifi-release/device-identifier/v1\x00"
            b"unist19\x00abcdef0123456789"
        )
        self.assertEqual(
            hmac.new(key, message, hashlib.sha256).hexdigest()[:32],
            "cb101f2c0e29decfdc0d873233589247",
        )


if __name__ == "__main__":
    unittest.main()
