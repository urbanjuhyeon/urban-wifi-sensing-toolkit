from __future__ import annotations

import importlib.util
import json
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
BUILDER_PATH = REPOSITORY_ROOT / "scripts" / "pipeline" / "build_synthetic_tutorial_archive.py"
SPEC = importlib.util.spec_from_file_location("synthetic_archive_builder", BUILDER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load archive builder: {BUILDER_PATH}")
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


class SyntheticTutorialArchiveTest(unittest.TestCase):
    def build_in(self, directory: Path, stem: str = "tutorial") -> tuple[Path, Path, str]:
        archive = directory / f"{stem}.zip"
        checksum = directory / f"{stem}.zip.sha256"
        digest = BUILDER.build_archive(REPOSITORY_ROOT, archive, checksum)
        return archive, checksum, digest

    def test_two_builds_are_byte_identical(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first, first_checksum, first_digest = self.build_in(root, "first")
            second, second_checksum, second_digest = self.build_in(root, "second")
            self.assertEqual(first.read_bytes(), second.read_bytes())
            self.assertEqual(first_digest, second_digest)
            self.assertEqual(BUILDER.sha256_file(first), first_digest)
            self.assertEqual(BUILDER.sha256_file(second), second_digest)
            # Sidecars name their own archives, so only the digest field is equal.
            self.assertEqual(
                first_checksum.read_text(encoding="ascii").split()[0], first_digest
            )
            self.assertEqual(
                second_checksum.read_text(encoding="ascii").split()[0], second_digest
            )

    def test_members_order_and_metadata_are_frozen(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive, _, _ = self.build_in(Path(temporary))
            with zipfile.ZipFile(archive) as source:
                infos = source.infolist()
                self.assertEqual(
                    [info.filename for info in infos], sorted(BUILDER.ARCHIVE_ALLOWLIST)
                )
                self.assertEqual(source.comment, b"")
                for info in infos:
                    self.assertEqual(info.date_time, BUILDER.FIXED_ZIP_TIMESTAMP)
                    self.assertEqual(info.create_system, 3)
                    self.assertEqual(info.compress_type, zipfile.ZIP_DEFLATED)
                    self.assertEqual(
                        (info.external_attr >> 16) & 0xFFFF,
                        stat.S_IFREG | 0o644,
                    )
                    self.assertFalse(info.extra)
                    self.assertFalse(info.comment)

    def test_internal_manifest_and_synthetic_contract_verify(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive, checksum, digest = self.build_in(Path(temporary))
            payload = BUILDER.verify_archive(archive)
            self.assertEqual(set(payload), set(BUILDER.ARCHIVE_ALLOWLIST))
            self.assertEqual(BUILDER.verify_checksum(archive, checksum), digest)
            fixture = json.loads(payload[BUILDER.FIXTURE_MANIFEST])
            self.assertTrue(fixture["privacy_boundary"]["fully_synthetic"])
            self.assertFalse(fixture["privacy_boundary"]["raw_mac_addresses_stored"])
            self.assertEqual(
                fixture["database_sha256"],
                BUILDER.sha256_bytes(payload[BUILDER.FIXTURE_DATABASE]),
            )

    def test_verified_extraction_matches_every_member(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive, _, _ = self.build_in(root)
            destination = root / "extracted"
            written = BUILDER.extract_verified_archive(archive, destination)
            self.assertEqual(len(written), len(BUILDER.ARCHIVE_ALLOWLIST))
            payload = BUILDER.verify_archive(archive)
            for name, expected in payload.items():
                actual = destination.joinpath(*name.split("/"))
                self.assertEqual(actual.read_bytes(), expected)

    def test_tampered_member_fails_internal_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive, _, _ = self.build_in(root)
            tampered = root / "tampered.zip"
            with zipfile.ZipFile(archive, "r") as source, zipfile.ZipFile(
                tampered, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
            ) as output:
                for info in source.infolist():
                    data = source.read(info)
                    if info.filename == BUILDER.INTERNAL_README:
                        data += b"tampered\n"
                    output.writestr(info, data)
            with self.assertRaises(BUILDER.ArchiveValidationError):
                BUILDER.verify_archive(tampered)

    def test_path_traversal_archive_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "traversal.zip"
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("../outside.txt", b"not allowed")
            with self.assertRaises(BUILDER.ArchiveValidationError):
                BUILDER.verify_archive(archive)

    def test_scanner_rejects_raw_address_absolute_path_identity_and_key_copy(self) -> None:
        raw_address = ":".join(("aa", "bb", "cc", "dd", "ee", "ff")).encode()
        absolute_path = (
            "C:" + "\\" + "Users" + "\\" + "person" + "\\" + "secret.txt"
        ).encode()
        identity_url = ("https://" + "github" + ".com/example/repository").encode()
        email = ("person" + "@" + "example.org").encode()
        for data in (raw_address, absolute_path, identity_url, email):
            with self.subTest(data=data):
                with self.assertRaises(BUILDER.ArchiveValidationError):
                    BUILDER._scan_member("README.md", data)
        with self.assertRaises(BUILDER.ArchiveValidationError):
            BUILDER._scan_member("README.md", BUILDER.PUBLIC_TEST_KEY)

    def test_nonempty_extraction_destination_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive, _, _ = self.build_in(root)
            destination = root / "occupied"
            destination.mkdir()
            (destination / "keep.txt").write_text("preserve", encoding="utf-8")
            with self.assertRaises(BUILDER.ArchiveValidationError):
                BUILDER.extract_verified_archive(archive, destination)
            self.assertEqual(
                (destination / "keep.txt").read_text(encoding="utf-8"), "preserve"
            )


if __name__ == "__main__":
    unittest.main()
