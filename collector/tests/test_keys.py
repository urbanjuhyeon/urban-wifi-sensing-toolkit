import os
import tempfile
import unittest
from pathlib import Path

from urban_wifi_capture.keys import (
    KeyFileError,
    generate_pseudonymization_key,
    load_pseudonymization_key,
)


class KeyFileTests(unittest.TestCase):
    def test_generator_creates_exact_private_random_key_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "deployment.key"
            self.assertEqual(generate_pseudonymization_key(path), path.absolute())
            first = load_pseudonymization_key(path)
            self.assertEqual(len(first), 32)
            if os.name == "posix":
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(KeyFileError):
                generate_pseudonymization_key(path)
            self.assertEqual(path.read_bytes(), first)

    def test_loader_rejects_missing_short_long_and_text_encoded_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(KeyFileError):
                load_pseudonymization_key(root / "missing.key")
            for index, payload in enumerate((b"x" * 31, b"x" * 33, b"00" * 32, b"x" * 32 + b"\n")):
                path = root / f"bad-{index}.key"
                path.write_bytes(payload)
                if os.name == "posix":
                    path.chmod(0o600)
                with self.subTest(length=len(payload)), self.assertRaises(KeyFileError):
                    load_pseudonymization_key(path)

    def test_loader_rejects_multiple_hardlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "deployment.key"
            path.write_bytes(bytes(range(32)))
            if os.name == "posix":
                path.chmod(0o600)
            alias = root / "alias.key"
            try:
                os.link(path, alias)
            except OSError as exc:
                self.skipTest(f"hard links unavailable: {exc}")
            with self.assertRaises(KeyFileError):
                load_pseudonymization_key(path)

    def test_loader_and_generator_reject_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target.key"
            target.write_bytes(bytes(range(32)))
            if os.name == "posix":
                target.chmod(0o600)
            link = root / "deployment.key"
            try:
                link.symlink_to(target)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            with self.assertRaises(KeyFileError):
                load_pseudonymization_key(link)
            with self.assertRaises(KeyFileError):
                generate_pseudonymization_key(link)

    @unittest.skipUnless(os.name == "posix", "POSIX permission test")
    def test_loader_rejects_unsafe_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "deployment.key"
            path.write_bytes(bytes(range(32)))
            path.chmod(0o640)
            with self.assertRaises(KeyFileError):
                load_pseudonymization_key(path)


if __name__ == "__main__":
    unittest.main()
