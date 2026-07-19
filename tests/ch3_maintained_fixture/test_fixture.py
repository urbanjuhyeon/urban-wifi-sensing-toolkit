from __future__ import annotations

import hashlib
import importlib.util
import json
import re
import sqlite3
import tempfile
import unittest
from csv import DictReader
from collections import defaultdict
from contextlib import closing
from datetime import datetime, timedelta, timezone
from pathlib import Path
from statistics import median


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_DIR = (
    REPOSITORY_ROOT / "workflow" / "ch3_tutorial" / "maintained_capture_fixture"
)
GENERATOR_PATH = FIXTURE_DIR / "generate_fixture.py"

SPEC = importlib.util.spec_from_file_location("generate_fixture", GENERATOR_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load fixture generator: {GENERATOR_PATH}")
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_timestamp(value: str) -> datetime:
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ").replace(
        tzinfo=timezone.utc
    )


class MaintainedCaptureFixtureTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.database_path = FIXTURE_DIR / GENERATOR.DATABASE_NAME
        cls.manifest_path = FIXTURE_DIR / GENERATOR.MANIFEST_NAME
        cls.sensor_metadata_path = FIXTURE_DIR / GENERATOR.SENSOR_METADATA_NAME
        if not all(
            path.is_file()
            for path in (
                cls.database_path,
                cls.manifest_path,
                cls.sensor_metadata_path,
            )
        ):
            raise AssertionError(
                "run generate_fixture.py and commit all generated files"
            )
        cls.manifest = json.loads(cls.manifest_path.read_text(encoding="utf-8"))

    def connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database_path)
        connection.row_factory = sqlite3.Row
        return connection

    def test_committed_fixture_matches_a_fresh_deterministic_build(self) -> None:
        with (
            tempfile.TemporaryDirectory() as first,
            tempfile.TemporaryDirectory() as second,
        ):
            first_db, first_manifest, first_sensors = GENERATOR.build_fixture(
                Path(first)
            )
            second_db, second_manifest, second_sensors = GENERATOR.build_fixture(
                Path(second)
            )
            self.assertEqual(first_db.read_bytes(), second_db.read_bytes())
            self.assertEqual(first_manifest.read_bytes(), second_manifest.read_bytes())
            self.assertEqual(first_sensors.read_bytes(), second_sensors.read_bytes())
            self.assertEqual(self.database_path.read_bytes(), first_db.read_bytes())
            self.assertEqual(
                self.manifest_path.read_bytes(), first_manifest.read_bytes()
            )
            self.assertEqual(
                self.sensor_metadata_path.read_bytes(), first_sensors.read_bytes()
            )

            first_hash = sha256(first_db)
            GENERATOR.build_fixture(Path(first))
            self.assertEqual(first_hash, sha256(first_db))

    def test_packets_table_has_exact_maintained_contract(self) -> None:
        with closing(self.connect()) as connection:
            table_names = {
                row[0]
                for row in connection.execute(
                    "SELECT name FROM sqlite_schema WHERE type = 'table'"
                )
            }
            columns = [
                row[1] for row in connection.execute("PRAGMA table_info(packets)")
            ]
            rows = connection.execute("SELECT * FROM packets").fetchall()

        self.assertEqual(table_names, {"packets"})
        self.assertEqual(columns, list(GENERATOR.PACKET_COLUMNS))
        self.assertEqual(len(rows), self.manifest["row_count"])
        self.assertGreater(len(rows), 1_000)

        identifier_pattern = re.compile(r"^[0-9a-f]{32}$")
        timestamp_pattern = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$")
        for row in rows:
            self.assertRegex(row["source_address"], identifier_pattern)
            self.assertRegex(row["timestamp"], timestamp_pattern)
            self.assertIn(row["source_address_randomized"], (0, 1))
            self.assertIn(row["sensor_name"], (GENERATOR.SENSOR_A, GENERATOR.SENSOR_B))

    def test_database_contains_no_capture_fields_outside_the_contract(self) -> None:
        with closing(self.connect()) as connection:
            schema = "\n".join(
                row[0]
                for row in connection.execute(
                    "SELECT sql FROM sqlite_schema WHERE sql IS NOT NULL"
                )
            ).lower()

        forbidden_schema_terms = (
            "bssid",
            "destination",
            "frame_bytes",
            "packet_bytes",
            "payload",
            "raw_address",
            "ssid",
        )
        for term in forbidden_schema_terms:
            self.assertNotIn(term, schema)

        database_bytes = self.database_path.read_bytes()
        colon_delimited_six_byte_value = re.compile(
            rb"(?i)(?:[0-9a-f]{2}:){5}[0-9a-f]{2}"
        )
        self.assertIsNone(colon_delimited_six_byte_value.search(database_bytes))

    def test_scenarios_exercise_cleaning_and_aggregation(self) -> None:
        with closing(self.connect()) as connection:
            rows = connection.execute(
                "SELECT timestamp, source_address, source_address_randomized, "
                "sensor_name FROM packets ORDER BY timestamp"
            ).fetchall()

        by_identifier: dict[str, list[sqlite3.Row]] = defaultdict(list)
        one_second_groups: dict[tuple[str, str, str], int] = defaultdict(int)
        twenty_second_groups: set[tuple[str, str, datetime]] = set()
        for row in rows:
            by_identifier[row["source_address"]].append(row)
            captured_at = parse_timestamp(row["timestamp"])
            second = captured_at.replace(microsecond=0)
            window = second.replace(second=(second.second // 20) * 20)
            one_second_groups[
                (row["source_address"], row["sensor_name"], second.isoformat())
            ] += 1
            twenty_second_groups.add(
                (row["source_address"], row["sensor_name"], window)
            )

        moving = by_identifier[GENERATOR.MOVING_RETAINED]
        moving_times = [parse_timestamp(row["timestamp"]) for row in moving]
        self.assertEqual(
            {row["sensor_name"] for row in moving},
            {GENERATOR.SENSOR_A, GENERATOR.SENSOR_B},
        )
        self.assertEqual({row["source_address_randomized"] for row in moving}, {0})
        local_timezone = timezone(timedelta(hours=9))
        self.assertEqual(
            {
                value.astimezone(local_timezone).date().isoformat()
                for value in moving_times
            },
            {"2024-01-15", "2024-01-16"},
        )

        moving_by_sensor: dict[str, list[datetime]] = defaultdict(list)
        for row in moving:
            moving_by_sensor[row["sensor_name"]].append(
                parse_timestamp(row["timestamp"])
            )
        session_durations: list[float] = []
        for sensor_times in moving_by_sensor.values():
            current_session = [min(sensor_times)]
            for captured_at in sorted(sensor_times)[1:]:
                if (captured_at - current_session[-1]).total_seconds() > 300:
                    session_durations.append(
                        (current_session[-1] - current_session[0]).total_seconds()
                    )
                    current_session = [captured_at]
                else:
                    current_session.append(captured_at)
            session_durations.append(
                (current_session[-1] - current_session[0]).total_seconds()
            )
        self.assertTrue(session_durations)
        self.assertLess(max(session_durations), 7_200)

        stationary = by_identifier[GENERATOR.STATIONARY_OVER_TWO_HOURS]
        stationary_times = [parse_timestamp(row["timestamp"]) for row in stationary]
        self.assertEqual(
            {row["sensor_name"] for row in stationary}, {GENERATOR.SENSOR_A}
        )
        self.assertGreater(
            (max(stationary_times) - min(stationary_times)).total_seconds(), 7_200
        )

        activity_stay = by_identifier[GENERATOR.ACTIVITY_STAY_RETAINED]
        activity_times = [parse_timestamp(row["timestamp"]) for row in activity_stay]
        activity_span = (max(activity_times) - min(activity_times)).total_seconds()
        self.assertGreaterEqual(activity_span, 300)
        self.assertLess(activity_span, 7_200)
        self.assertEqual(
            {row["sensor_name"] for row in activity_stay}, {GENERATOR.SENSOR_B}
        )

        randomized_identifiers = {
            identifier
            for identifier, identifier_rows in by_identifier.items()
            if {row["source_address_randomized"] for row in identifier_rows} == {1}
        }
        self.assertEqual(
            randomized_identifiers,
            {GENERATOR.RANDOMIZED_VISITOR_A, GENERATOR.RANDOMIZED_VISITOR_B},
        )
        self.assertTrue(any(count > 1 for count in one_second_groups.values()))
        self.assertEqual(len(one_second_groups), 698)
        self.assertEqual(len(twenty_second_groups), 414)

    def test_identifiers_use_the_public_test_only_deployment_hmac_contract(self) -> None:
        identifiers = {
            GENERATOR.MOVING_RETAINED,
            GENERATOR.STATIONARY_OVER_TWO_HOURS,
            GENERATOR.RANDOMIZED_VISITOR_A,
            GENERATOR.RANDOMIZED_VISITOR_B,
            GENERATOR.ACTIVITY_STAY_RETAINED,
        }
        self.assertEqual(len(identifiers), 5)
        self.assertEqual(
            GENERATOR.MOVING_RETAINED,
            "20bb0f1ddb10c9b71fa916d5a7d078c6",
        )
        self.assertEqual(
            GENERATOR.synthetic_identifier("moving-retained"),
            GENERATOR.MOVING_RETAINED,
        )
        self.assertNotEqual(
            GENERATOR.synthetic_identifier(
                "moving-retained", deployment_id="OTHER_DEPLOYMENT"
            ),
            GENERATOR.MOVING_RETAINED,
        )
        self.assertNotEqual(
            GENERATOR.synthetic_identifier(
                "moving-retained", key=bytes(range(1, 33))
            ),
            GENERATOR.MOVING_RETAINED,
        )
        with self.assertRaises(ValueError):
            GENERATOR.synthetic_identifier("moving-retained", key=b"too-short")

    def test_default_cleaning_contract_preserves_the_frozen_stage_counts(self) -> None:
        with closing(self.connect()) as connection:
            rows = connection.execute(
                "SELECT timestamp, subtype, strength, source_address, "
                "source_address_randomized, sensor_name FROM packets"
            ).fetchall()

        grouped: dict[tuple[datetime, str, str], list[sqlite3.Row]] = defaultdict(list)
        for row in rows:
            if not -80 <= row["strength"] <= -30:
                continue
            if row["subtype"].lower() in {"beacon", "probe-response"}:
                continue
            second = parse_timestamp(row["timestamp"]).replace(microsecond=0)
            grouped[(second, row["source_address"], row["sensor_name"])].append(row)

        one_second = []
        for (second, identifier, sensor_name), packets in grouped.items():
            randomized_flags = {
                packet["source_address_randomized"] for packet in packets
            }
            self.assertEqual(len(randomized_flags), 1)
            one_second.append(
                (
                    second,
                    identifier,
                    sensor_name,
                    randomized_flags.pop(),
                    float(median(packet["strength"] for packet in packets)),
                    len(packets),
                )
            )
        self.assertEqual(len(one_second), 698)

        nonrandom = [row for row in one_second if row[3] == 0]
        sensor_sessions: dict[tuple[str, str], list[datetime]] = defaultdict(list)
        for second, identifier, sensor_name, *_ in nonrandom:
            sensor_sessions[(identifier, sensor_name)].append(second)

        stationary_identifiers: set[str] = set()
        for (identifier, _), timestamps in sensor_sessions.items():
            session = [min(timestamps)]
            for captured_at in sorted(timestamps)[1:]:
                if (captured_at - session[-1]).total_seconds() > 300:
                    if (session[-1] - session[0]).total_seconds() > 7_200:
                        stationary_identifiers.add(identifier)
                    session = [captured_at]
                else:
                    session.append(captured_at)
            if (session[-1] - session[0]).total_seconds() > 7_200:
                stationary_identifiers.add(identifier)

        self.assertEqual(
            stationary_identifiers, {GENERATOR.STATIONARY_OVER_TWO_HOURS}
        )
        cleaned = [
            row for row in nonrandom if row[1] not in stationary_identifiers
        ]
        self.assertEqual(len(cleaned), 242)
        self.assertEqual(
            {row[1] for row in cleaned},
            {GENERATOR.MOVING_RETAINED, GENERATOR.ACTIVITY_STAY_RETAINED},
        )
        windows = {
            (
                second.replace(second=(second.second // 20) * 20),
                identifier,
                sensor_name,
            )
            for second, identifier, sensor_name, *_ in cleaned
        }
        self.assertEqual(len(windows), 34)

    def test_manifest_records_database_digest_and_privacy_boundary(self) -> None:
        self.assertEqual(self.manifest["database_sha256"], sha256(self.database_path))
        self.assertEqual(
            self.manifest["sensor_metadata_sha256"],
            sha256(self.sensor_metadata_path),
        )
        self.assertEqual(
            self.manifest["packet_columns"], list(GENERATOR.PACKET_COLUMNS)
        )
        self.assertEqual(
            self.manifest["sensors"], [GENERATOR.SENSOR_A, GENERATOR.SENSOR_B]
        )
        self.assertTrue(self.manifest["privacy_boundary"]["fully_synthetic"])
        self.assertFalse(
            self.manifest["privacy_boundary"]["original_address_mapping_exists"]
        )
        for field in (
            "bssids_stored",
            "destination_addresses_stored",
            "frame_bytes_stored",
            "raw_mac_addresses_stored",
            "ssids_stored",
        ):
            self.assertFalse(self.manifest["privacy_boundary"][field])
        self.assertEqual(
            set(self.manifest["metric_smoke_test_roles"]),
            {"Location", "Count", "Track", "Revisits", "Activities"},
        )
        scope = self.manifest["fixture_scope"]
        self.assertTrue(scope["minimal_packets_fixture"])
        self.assertTrue(scope["no_hardware_capture_occurred"])
        self.assertFalse(scope["operational_loss_counters_fabricated"])
        self.assertEqual(
            scope["omitted_operational_tables"],
            {
                "capture_interface_summary": (
                    "omitted because no hardware capture occurred"
                ),
                "capture_metadata": "omitted because no hardware capture occurred",
            },
        )
        contract = self.manifest["identifier_contract"]
        self.assertEqual(contract["algorithm"], GENERATOR.IDENTIFIER_ALGORITHM)
        self.assertEqual(contract["scheme"], GENERATOR.IDENTIFIER_SCHEME)
        self.assertEqual(contract["scope"], "deployment")
        self.assertEqual(contract["deployment_id"], GENERATOR.TEST_DEPLOYMENT_ID)
        self.assertEqual(
            contract["public_test_key_hex"], GENERATOR.TEST_ONLY_HMAC_KEY_HEX
        )
        self.assertTrue(contract["key_is_public"])
        self.assertTrue(contract["key_is_test_only"])
        self.assertTrue(contract["key_must_not_be_used_for_field_collection"])
        self.assertFalse(contract["key_is_secret"])
        self.assertEqual(
            contract["security_notice"],
            "PUBLIC TEST KEY; never use this value for field collection",
        )
        self.assertEqual(contract["lowercase_hex_characters"], 32)
        self.assertIn("not MAC addresses", contract["input_kind"])
        self.assertFalse(
            self.manifest["privacy_boundary"][
                "mac_addresses_used_as_identifier_inputs"
            ]
        )
        self.assertEqual(
            self.manifest["role_aware_packet_contract_sha256"],
            GENERATOR.ROLE_AWARE_PACKET_CONTRACT_SHA256,
        )
        self.assertEqual(
            GENERATOR._role_aware_packet_contract_sha256(
                GENERATOR.fixture_packets()
            ),
            "2c2f5569d921e5dbfdc326584d62edd94a1cea171737f046306b971430178ed2",
        )

    def test_sensor_metadata_uses_only_virtual_local_coordinates(self) -> None:
        with self.sensor_metadata_path.open(encoding="utf-8", newline="") as handle:
            rows = list(DictReader(handle))

        self.assertEqual([row["sensor_name"] for row in rows], ["A01", "A02"])
        self.assertEqual({row["is_synthetic"] for row in rows}, {"1"})
        self.assertEqual(
            {row["coordinate_system"] for row in rows},
            {"local_cartesian_metres"},
        )
        self.assertEqual(
            [(float(row["x"]), float(row["y"])) for row in rows],
            [(0.0, 0.0), (75.0, 0.0)],
        )


if __name__ == "__main__":
    unittest.main()
