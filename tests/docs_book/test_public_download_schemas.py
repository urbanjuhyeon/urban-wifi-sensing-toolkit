from __future__ import annotations

import hashlib
import re
import sqlite3
import tempfile
import unittest
import zipfile
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DOWNLOADS = REPOSITORY_ROOT / "docs" / "downloads"

PACKET_CONTRACT = (
    ("timestamp", "TEXT", 1),
    ("type", "TEXT", 1),
    ("subtype", "TEXT", 1),
    ("strength", "INTEGER", 1),
    ("source_address", "TEXT", 1),
    ("source_address_randomized", "INTEGER", 1),
    ("channel", "INTEGER", 1),
    ("sensor_name", "TEXT", 1),
)

RETIRED_DOWNLOADS = (
    "sample_raw.zip",
    "sample_aggregated.zip",
    "sample_location.zip",
    "sample_track.zip",
)
RETIRED_SOURCE_PATHS = (
    "workflow/ch3_tutorial/sample_1.sqlite3",
    "workflow/ch3_tutorial/sample_2.sqlite3",
    "workflow/ch3_tutorial/sample_raw.zip",
    "workflow/ch3_tutorial/sample_1_1second.csv",
    "workflow/ch3_tutorial/sample_2_1second.csv",
    "workflow/ch3_tutorial/sample_aggregated.zip",
    "workflow/ch3_tutorial/aggregated_sample_1.csv",
    "workflow/ch3_tutorial/cleaned_sample.csv",
    "workflow/ch3_tutorial/sample_track.zip",
)
FIELD_DERIVED_ARCHIVES = (
    "sample_main.zip",
    "sample_loc.zip",
)
CHECKSUM_LINE = re.compile(r"^([0-9a-f]{64})  ([A-Za-z0-9_.-]+)$")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class PublicDownloadSchemaTest(unittest.TestCase):
    def test_every_public_packets_table_uses_exact_maintained_contract(self) -> None:
        packet_tables: list[str] = []
        with tempfile.TemporaryDirectory() as temporary:
            temporary_root = Path(temporary)
            for archive_path in sorted(DOWNLOADS.glob("*.zip")):
                with zipfile.ZipFile(archive_path, "r") as archive:
                    for index, member in enumerate(archive.infolist()):
                        if Path(member.filename).suffix.lower() not in {
                            ".db",
                            ".sqlite",
                            ".sqlite3",
                        }:
                            continue
                        database_path = temporary_root / f"{archive_path.stem}-{index}.sqlite3"
                        database_path.write_bytes(archive.read(member))
                        connection = sqlite3.connect(
                            f"file:{database_path.resolve()}?mode=ro", uri=True
                        )
                        try:
                            table = connection.execute(
                                "SELECT 1 FROM sqlite_schema "
                                "WHERE type='table' AND name='packets'"
                            ).fetchone()
                            if table is None:
                                continue
                            label = f"{archive_path.name}::{member.filename}"
                            packet_tables.append(label)
                            actual = tuple(
                                (row[1], row[2].upper(), row[3])
                                for row in connection.execute(
                                    "PRAGMA table_info('packets')"
                                )
                            )
                            self.assertEqual(actual, PACKET_CONTRACT, label)
                        finally:
                            connection.close()
        self.assertTrue(packet_tables, "no public ZIP contains the maintained packets fixture")

    def test_retired_chapter3_processing_artifacts_do_not_recur(self) -> None:
        for filename in RETIRED_DOWNLOADS:
            self.assertFalse((DOWNLOADS / filename).exists(), filename)
        for relative in RETIRED_SOURCE_PATHS:
            self.assertFalse((REPOSITORY_ROOT / relative).exists(), relative)

    def test_field_derived_checksum_manifest_covers_exactly_the_archives(self) -> None:
        manifest = DOWNLOADS / "sample-archives.sha256"
        entries: dict[str, str] = {}
        for line in manifest.read_text(encoding="ascii").splitlines():
            match = CHECKSUM_LINE.fullmatch(line)
            self.assertIsNotNone(match, line)
            assert match is not None
            digest, filename = match.groups()
            self.assertNotIn(filename, entries)
            entries[filename] = digest
        self.assertEqual(tuple(entries), FIELD_DERIVED_ARCHIVES)
        for filename, expected in entries.items():
            self.assertEqual(sha256_file(DOWNLOADS / filename), expected, filename)


if __name__ == "__main__":
    unittest.main()
