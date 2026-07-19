from __future__ import annotations

import hashlib
import importlib.util
import io
import shutil
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
BUILDER_PATH = REPOSITORY_ROOT / "scripts" / "docs" / "build_capture_archive.py"
DOC_VERIFIER_DIR = REPOSITORY_ROOT / "scripts" / "docs"
sys.path.insert(0, str(DOC_VERIFIER_DIR))

import verify_online_book as VERIFIER  # noqa: E402


def load_builder():
    specification = importlib.util.spec_from_file_location(
        "build_capture_archive", BUILDER_PATH
    )
    if specification is None or specification.loader is None:
        raise RuntimeError("cannot load capture archive builder")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


BUILDER = load_builder()


class CaptureArchiveBuilderTests(unittest.TestCase):
    def test_committed_artifacts_equal_a_fresh_source_rebuild(self):
        digest = BUILDER.check_artifacts()
        self.assertEqual(
            digest,
            hashlib.sha256(BUILDER.DEFAULT_ARCHIVE.read_bytes()).hexdigest(),
        )

    def test_two_builds_are_byte_identical(self):
        first = BUILDER.build_archive_bytes()
        second = BUILDER.build_archive_bytes()
        self.assertEqual(first, second)

    def test_archive_member_set_manifest_and_modes_are_exact(self):
        archive_bytes = BUILDER.build_archive_bytes()
        with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
            infos = archive.infolist()
            expected_names = [
                f"{BUILDER.ARCHIVE_PREFIX}{name}" for name in BUILDER.SOURCE_MEMBERS
            ] + [
                f"{BUILDER.ARCHIVE_PREFIX}{BUILDER.INTERNAL_MANIFEST}"
            ]
            self.assertEqual([info.filename for info in infos], expected_names)
            self.assertTrue(all(info.date_time == BUILDER.ARCHIVE_TIMESTAMP for info in infos))
            self.assertTrue(all(info.compress_type == zipfile.ZIP_STORED for info in infos))
            self.assertTrue(all(info.create_system == 3 for info in infos))
            self.assertEqual(archive.comment, b"")

            for info in infos:
                relative = info.filename.removeprefix(BUILDER.ARCHIVE_PREFIX)
                expected_mode = (
                    0o100755
                    if relative in BUILDER.EXECUTABLE_MEMBERS
                    else 0o100644
                )
                self.assertEqual((info.external_attr >> 16) & 0xFFFF, expected_mode)

            manifest = archive.read(
                f"{BUILDER.ARCHIVE_PREFIX}{BUILDER.INTERNAL_MANIFEST}"
            )
            expected_manifest = BUILDER.build_internal_manifest(
                BUILDER.read_source_tree()
            )
            self.assertEqual(manifest, expected_manifest)

    def test_unexpected_source_member_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "collector"
            shutil.copytree(BUILDER.DEFAULT_SOURCE_ROOT, source)
            (source / "unexpected.sqlite3").write_bytes(b"not a database\n")
            with self.assertRaisesRegex(
                BUILDER.CaptureArchiveBuildError, "unexpected"
            ):
                BUILDER.build_archive_bytes(source)

    def test_check_rejects_source_artifact_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "collector"
            archive = root / BUILDER.DEFAULT_ARCHIVE.name
            checksum = root / BUILDER.DEFAULT_CHECKSUM.name
            shutil.copytree(BUILDER.DEFAULT_SOURCE_ROOT, source)
            BUILDER.write_artifacts(source, archive, checksum)
            (source / "README.md").write_bytes(
                (source / "README.md").read_bytes() + b"drift\n"
            )
            with self.assertRaisesRegex(
                BUILDER.CaptureArchiveBuildError, "differs"
            ):
                BUILDER.check_artifacts(source, archive, checksum)

    def test_crlf_checkout_normalizes_to_the_same_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "collector"
            shutil.copytree(BUILDER.DEFAULT_SOURCE_ROOT, source)
            path = source / "README.md"
            path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))
            self.assertEqual(
                BUILDER.build_archive_bytes(source),
                BUILDER.build_archive_bytes(BUILDER.DEFAULT_SOURCE_ROOT),
            )

    def test_online_book_verifier_enforces_the_source_rebuild(self):
        digest = VERIFIER._verify_capture_archive(
            BUILDER.DEFAULT_ARCHIVE,
            BUILDER.DEFAULT_CHECKSUM,
            REPOSITORY_ROOT,
        )
        self.assertEqual(
            digest, BUILDER.sha256_bytes(BUILDER.DEFAULT_ARCHIVE.read_bytes())
        )

    def test_online_book_verifier_rejects_canonical_source_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory) / "repository"
            source = repository / "collector"
            builder_path = repository / VERIFIER.CAPTURE_BUILDER
            archive = repository / "rendered" / VERIFIER.CAPTURE_ARCHIVE.name
            checksum = repository / "rendered" / VERIFIER.CAPTURE_CHECKSUM.name
            shutil.copytree(BUILDER.DEFAULT_SOURCE_ROOT, source)
            builder_path.parent.mkdir(parents=True)
            shutil.copy2(BUILDER_PATH, builder_path)
            BUILDER.write_artifacts(source, archive, checksum)
            (source / "README.md").write_bytes(
                (source / "README.md").read_bytes() + b"source drift\n"
            )
            with self.assertRaisesRegex(
                VERIFIER.OnlineBookValidationError, "drift"
            ):
                VERIFIER._verify_capture_archive(
                    archive, checksum, repository
                )


if __name__ == "__main__":
    unittest.main()
