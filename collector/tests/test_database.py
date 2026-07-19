import os
import queue
import sqlite3
import tempfile
import threading
import time
import unittest
from pathlib import Path

from urban_wifi_capture.database import (
    CREATE_METADATA_SQL,
    CREATE_PACKETS_SQL,
    CREATE_SUMMARY_SQL,
    PACKET_COLUMNS,
    SchemaMismatchError,
    connect_database,
    metadata_for_deployment,
    writer_loop,
)
from urban_wifi_capture.identifiers import Pseudonymizer, classify_and_pseudonymize_source
from urban_wifi_capture.model import CaptureSummary, PacketRecord

DEPLOYMENT_ID = "FIELDWORK_2026_01"
TEST_KEY = bytes(range(32))
PSEUDONYMIZER = Pseudonymizer(DEPLOYMENT_ID, TEST_KEY)


def sample_record(randomized=False, timestamp="2026-01-01T00:00:00.000001Z"):
    raw = "AA:BB:CC:DD:EE:FF" if randomized else "A8:BB:CC:DD:EE:FF"
    token = classify_and_pseudonymize_source(raw, PSEUDONYMIZER)
    return PacketRecord(
        timestamp=timestamp,
        type="management",
        subtype="probe-request",
        strength=-55,
        source_address=token.identifier,
        source_address_randomized=token.randomized,
        channel=1,
        sensor_name="A01",
    )


class DatabaseTests(unittest.TestCase):
    def test_packet_model_matches_the_exact_sqlite_column_contract(self):
        expected = (
            "timestamp",
            "type",
            "subtype",
            "strength",
            "source_address",
            "source_address_randomized",
            "channel",
            "sensor_name",
        )
        self.assertEqual(PACKET_COLUMNS, expected)
        self.assertEqual(tuple(PacketRecord.__dataclass_fields__), expected)
        self.assertEqual(len(sample_record().as_tuple()), len(expected))

    def test_metadata_rejects_nonopaque_deployment_id(self):
        for value in ("", "site name", "A" * 65):
            with self.subTest(value=value), self.assertRaises(ValueError):
                metadata_for_deployment(value)

    def test_partial_batch_commits_by_maximum_age_during_continuous_arrivals(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "age.sqlite3"
            records = queue.Queue()
            thread = threading.Thread(
                target=writer_loop,
                args=(path, records, 1000, 1, 0.1),
                kwargs={"deployment_id": DEPLOYMENT_ID},
            )
            thread.start()

            def feed_continuously():
                for index in range(20):
                    records.put(
                        sample_record(
                            bool(index % 2),
                            f"2026-01-01T00:00:00.{index:06d}Z",
                        )
                    )
                    time.sleep(0.03)

            feeder = threading.Thread(target=feed_continuously)
            feeder.start()

            count = 0
            try:
                deadline = time.monotonic() + 0.45
                while time.monotonic() < deadline and feeder.is_alive():
                    connection = None
                    try:
                        connection = sqlite3.connect(
                            f"{path.absolute().as_uri()}?mode=ro", uri=True
                        )
                        count = connection.execute("SELECT count(*) FROM packets").fetchone()[0]
                    except sqlite3.Error:
                        count = 0
                    finally:
                        if connection is not None:
                            connection.close()
                    if count > 0:
                        break
                    time.sleep(0.02)

                self.assertTrue(feeder.is_alive(), "test must observe a commit during arrivals")
                self.assertGreater(count, 0)
                self.assertTrue(thread.is_alive())
            finally:
                feeder.join(timeout=2)
                records.put(None)
                thread.join(timeout=10)
            self.assertFalse(feeder.is_alive())
            self.assertFalse(thread.is_alive())

    def test_capture_summary_counter_availability_contract(self):
        common = dict(
            interface="wlan1mon",
            channel=1,
            pcap_received=-1,
            pcap_dropped=-1,
            interface_dropped=-1,
            queue_dropped=0,
            records_emitted=0,
            records_filtered=0,
            completed_at="2026-01-01T00:00:02.000001Z",
        )
        CaptureSummary(**common)
        for field in ("queue_dropped", "records_emitted", "records_filtered"):
            invalid = {**common, field: -1}
            with self.subTest(field=field), self.assertRaises(ValueError):
                CaptureSummary(**invalid)

    def test_writer_waits_for_all_producers_and_stores_loss_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "multi.sqlite3"
            records = queue.Queue()
            thread = threading.Thread(
                target=writer_loop,
                args=(path, records, 2, 2),
                kwargs={"deployment_id": DEPLOYMENT_ID},
            )
            thread.start()
            records.put(sample_record())
            records.put(None)
            records.put(sample_record(True, "2026-01-01T00:00:01.000001Z"))
            records.put(
                CaptureSummary(
                    interface="wlan1mon",
                    channel=1,
                    pcap_received=2,
                    pcap_dropped=0,
                    interface_dropped=0,
                    queue_dropped=0,
                    records_emitted=2,
                    records_filtered=0,
                    completed_at="2026-01-01T00:00:02.000001Z",
                )
            )
            self.assertTrue(thread.is_alive())
            records.put(None)
            thread.join(timeout=10)
            self.assertFalse(thread.is_alive())
            connection = sqlite3.connect(path)
            count = connection.execute("SELECT count(*) FROM packets").fetchone()[0]
            summary = connection.execute(
                "SELECT interface,pcap_received,pcap_dropped,interface_dropped,queue_dropped,"
                "records_emitted,records_filtered "
                "FROM capture_interface_summary"
            ).fetchone()
            connection.close()
            self.assertEqual(count, 2)
            self.assertEqual(summary, ("wlan1mon", 2, 0, 0, 0, 2, 0))

    def test_writer_schema_metadata_and_privacy_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.sqlite3"
            records = queue.Queue()
            thread = threading.Thread(
                target=writer_loop,
                args=(path, records, 2),
                kwargs={"deployment_id": DEPLOYMENT_ID},
            )
            thread.start()
            records.put(sample_record())
            records.put(sample_record(True, "2026-01-01T00:00:01.000001Z"))
            records.put(None)
            thread.join(timeout=10)
            self.assertFalse(thread.is_alive())

            connection = sqlite3.connect(path)
            columns = tuple(row[1] for row in connection.execute("PRAGMA table_info(packets)"))
            metadata = dict(connection.execute("SELECT key, value FROM capture_metadata"))
            rows = connection.execute(
                "SELECT sensor_name,timestamp,type,subtype,strength AS rssi,"
                "source_address,source_address_randomized FROM packets ORDER BY timestamp"
            ).fetchall()
            connection.close()

            self.assertEqual(columns, PACKET_COLUMNS)
            self.assertEqual(metadata, metadata_for_deployment(DEPLOYMENT_ID))
            self.assertEqual(metadata["identifier_scope"], "deployment")
            self.assertEqual(metadata["deployment_id"], DEPLOYMENT_ID)
            self.assertFalse(any("key" in name or "fingerprint" in name for name in metadata))
            self.assertEqual(len(rows), 2)
            self.assertEqual([row[-1] for row in rows], [0, 1])
            self.assertTrue(all(len(row[-2]) == 32 for row in rows))

            persisted = b"".join(
                item.read_bytes()
                for item in path.parent.iterdir()
                if item.name.startswith(path.name)
            )
            self.assertNotIn(b"aa:bb:cc:dd:ee:ff", persisted.lower())
            self.assertNotIn(bytes.fromhex("aabbccddeeff"), persisted)
            self.assertNotIn(b"Private-Network-Name", persisted)
            self.assertNotIn(TEST_KEY, persisted)

    def test_sqlite_constraints_reject_noncanonical_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.sqlite3"
            connection = connect_database(path, DEPLOYMENT_ID)
            valid = sample_record().as_tuple()
            invalid_hash = list(valid)
            invalid_hash[4] = "AA:BB:CC:DD:EE:FF"
            legacy_hash = list(valid)
            legacy_hash[4] = "0123456789abcdef"
            uppercase_hash = list(valid)
            uppercase_hash[4] = str(valid[4]).upper()
            invalid_flag = list(valid)
            invalid_flag[5] = 2
            for row in (invalid_hash, legacy_hash, uppercase_hash, invalid_flag):
                with self.subTest(row=row), self.assertRaises(sqlite3.IntegrityError):
                    connection.execute("INSERT INTO packets VALUES (?,?,?,?,?,?,?,?)", row)
            connection.close()

    def test_existing_database_with_other_deployment_fails_without_relabeling(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.sqlite3"
            connection = connect_database(path, DEPLOYMENT_ID)
            connection.close()
            with self.assertRaises(SchemaMismatchError):
                connect_database(path, "FIELDWORK_2026_02")
            connection = sqlite3.connect(path)
            metadata = dict(connection.execute("SELECT key, value FROM capture_metadata"))
            connection.close()
            self.assertEqual(metadata["deployment_id"], DEPLOYMENT_ID)

    def test_legacy_16_hex_schema_fails_without_metadata_rewrite(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "legacy.sqlite3"
            connection = sqlite3.connect(path)
            connection.execute(
                CREATE_PACKETS_SQL.replace(
                    "length(source_address) = 32", "length(source_address) = 16"
                )
            )
            connection.execute(CREATE_METADATA_SQL)
            connection.execute(CREATE_SUMMARY_SQL)
            legacy = {"schema_version": "1", "identifier_algorithm": "sha256"}
            connection.executemany(
                "INSERT INTO capture_metadata (key, value) VALUES (?, ?)", legacy.items()
            )
            connection.commit()
            connection.close()
            if os.name == "posix":
                path.chmod(0o600)
            with self.assertRaises(SchemaMismatchError):
                connect_database(path, DEPLOYMENT_ID)
            connection = sqlite3.connect(path)
            metadata = dict(connection.execute("SELECT key, value FROM capture_metadata"))
            connection.close()
            self.assertEqual(metadata, legacy)

    @unittest.skipUnless(os.name == "posix", "POSIX permission test")
    def test_database_permissions_are_private(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.sqlite3"
            connection = connect_database(path, DEPLOYMENT_ID)
            connection.close()
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)

    @unittest.skipUnless(os.name == "posix", "POSIX symlink test")
    def test_database_rejects_symlinked_directory_component(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target"
            target.mkdir(mode=0o700)
            link = root / "linked"
            link.symlink_to(target, target_is_directory=True)
            with self.assertRaises(PermissionError):
                connect_database(link / "capture.sqlite3", DEPLOYMENT_ID)


if __name__ == "__main__":
    unittest.main()
