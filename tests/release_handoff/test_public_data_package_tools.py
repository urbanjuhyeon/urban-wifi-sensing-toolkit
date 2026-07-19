from __future__ import annotations

import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
RELEASE_SCRIPTS = REPOSITORY_ROOT / "scripts" / "release"
sys.path.insert(0, str(RELEASE_SCRIPTS))

import build_public_data_zip as zip_builder  # noqa: E402
import public_data_package_contract as contract  # noqa: E402
import scan_public_data_package as package_scanner  # noqa: E402
import verify_public_data_zip as zip_verifier  # noqa: E402


class PublicDataPackageToolsTest(unittest.TestCase):
    def make_package(self, repository_root: Path) -> Path:
        package_root = repository_root / "tmp" / "public-data-package"
        package = package_root / contract.PACKAGE_VERSION
        package.mkdir(parents=True)
        for filename in sorted(contract.MANIFEST_ENTRY_FILENAMES):
            (package / filename).write_bytes(
                f"synthetic test content for {filename}\n".encode("ascii")
            )
        self.rebuild_manifest(package)
        return package

    def rebuild_manifest(self, package: Path) -> None:
        lines = [
            f"{contract.sha256_file(package / filename)}  {filename}"
            for filename in sorted(contract.MANIFEST_ENTRY_FILENAMES)
        ]
        (package / contract.MANIFEST_FILENAME).write_text(
            "\n".join(lines) + "\n", encoding="ascii", newline="\n"
        )

    def test_builds_byte_identical_archives_and_verifies_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository_root = Path(temporary)
            package = self.make_package(repository_root)
            first = package.parent / "first.zip"
            second = package.parent / "second.zip"
            zip_builder.build_deterministic_zip(package, first, repository_root)
            zip_builder.build_deterministic_zip(package, second, repository_root)

            self.assertEqual(first.read_bytes(), second.read_bytes())
            first_hash, first_size = zip_verifier.verify_deterministic_zip(
                package, first, repository_root
            )
            self.assertEqual(first_hash, contract.sha256_file(first))
            self.assertEqual(first_size, first.stat().st_size)
            self.assertEqual(
                package_scanner.scan_package(package, repository_root, first)[0],
                len(contract.ALLOWED_PACKAGE_FILENAMES),
            )

    def test_refuses_overwrite_extra_files_and_outside_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository_root = Path(temporary)
            package = self.make_package(repository_root)
            output = package.parent / "candidate.zip"
            zip_builder.build_deterministic_zip(package, output, repository_root)
            with self.assertRaisesRegex(
                contract.PackageContractError, "overwrite"
            ):
                zip_builder.build_deterministic_zip(package, output, repository_root)

            (package / "unexpected.txt").write_text("extra", encoding="utf-8")
            with self.assertRaisesRegex(
                contract.PackageContractError, "allowlist"
            ):
                contract.package_files(package)
            (package / "unexpected.txt").unlink()

            outside = repository_root / "outside.zip"
            with self.assertRaisesRegex(
                contract.PackageContractError, "direct child"
            ):
                zip_builder.build_deterministic_zip(package, outside, repository_root)

    def test_scanner_detects_raw_mac_and_private_mapping_field_by_class(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository_root = Path(temporary)
            package = self.make_package(repository_root)
            readme = package / "README.md"
            readme.write_text(
                "forbidden internal_source_address and aa:bb:cc:dd:ee:ff\n",
                encoding="ascii",
                newline="\n",
            )
            self.rebuild_manifest(package)
            with self.assertRaises(package_scanner.PackageScanError) as raised:
                package_scanner.scan_package(package, repository_root)
            message = str(raised.exception)
            self.assertIn("private identifier-mapping field", message)
            self.assertIn("colon-delimited MAC-like value", message)
            self.assertNotIn("aa:bb:cc:dd:ee:ff", message)

    def test_zip_verifier_rejects_path_entries(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository_root = Path(temporary)
            package = self.make_package(repository_root)
            archive = package.parent / "malicious.zip"
            with zipfile.ZipFile(archive, mode="x") as zipped:
                zipped.writestr("../README.md", b"unsafe")
            with self.assertRaisesRegex(
                contract.PackageContractError, "allowlist|ordering"
            ):
                zip_verifier.verify_deterministic_zip(
                    package, archive, repository_root
                )

    def test_rejects_package_root_that_resolves_outside_repository(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, tempfile.TemporaryDirectory() as outside:
            repository_root = Path(temporary)
            (repository_root / "tmp").mkdir()
            try:
                (repository_root / "tmp" / "public-data-package").symlink_to(
                    Path(outside), target_is_directory=True
                )
            except OSError as exc:
                self.skipTest(f"directory symlinks are unavailable: {exc}")
            with self.assertRaisesRegex(
                contract.PackageContractError, "inside the repository"
            ):
                contract.package_root(repository_root)


if __name__ == "__main__":
    unittest.main()
