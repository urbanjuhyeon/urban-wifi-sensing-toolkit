#!/usr/bin/env python3
"""Build the deterministic, fully synthetic Chapter 3 capture fixture.

The fixture starts at the maintained collector's storage boundary.  It does
not represent intercepted traffic and cannot be mapped back to a device.  Its
identifiers are deterministic pseudonyms derived only from scenario labels.
It is intentionally a minimal ``packets``-only fixture: because no hardware
capture occurred, operational metadata, interface summaries, and loss counters
are omitted rather than fabricated.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import hmac
import json
import os
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterable, NamedTuple


FIXTURE_VERSION = 2
DATABASE_NAME = "maintained_capture.sqlite3"
MANIFEST_NAME = "manifest.json"
SENSOR_METADATA_NAME = "synthetic_sensors.csv"
BASE_TIME = datetime(2024, 1, 15, 0, 0, 0, tzinfo=timezone.utc)
LOCAL_TIMEZONE = timezone(timedelta(hours=9), name="Asia/Seoul")
SENSOR_A = "A01"
SENSOR_B = "A02"

# This deliberately public value exists only to make the fully synthetic
# fixture reproducible.  It is not a secret and must never be copied into a
# field deployment.  Real collectors require a separately generated secret
# 32-byte key for each deployment.
TEST_ONLY_HMAC_KEY = bytes(range(32))
TEST_ONLY_HMAC_KEY_HEX = TEST_ONLY_HMAC_KEY.hex()
TEST_DEPLOYMENT_ID = "SYNTHETIC_CH3_TEST_DEPLOYMENT"
IDENTIFIER_ALGORITHM = "HMAC-SHA-256 truncated to 128 bits"
IDENTIFIER_SCHEME = "synthetic-role-hmac-sha256-128-v1"
IDENTIFIER_SCOPE = "deployment"
IDENTIFIER_DOMAIN = b"urban-wifi-maintained-fixture"

# This frozen digest replaces each pseudonym with its synthetic scenario role
# before hashing the packet rows.  It therefore proves that changing the
# identifier scheme did not change any nonidentifier value or role assignment.
ROLE_AWARE_PACKET_CONTRACT_SHA256 = (
    "2c2f5569d921e5dbfdc326584d62edd94a1cea171737f046306b971430178ed2"
)

PACKET_COLUMNS = (
    "timestamp",
    "type",
    "subtype",
    "strength",
    "source_address",
    "source_address_randomized",
    "channel",
    "sensor_name",
)

CREATE_PACKETS_SQL = """
CREATE TABLE packets (
    timestamp TEXT NOT NULL
        CHECK(length(timestamp) = 27
              AND timestamp GLOB '????-??-??T??:??:??.??????Z'),
    type TEXT NOT NULL CHECK(type IN ('management', 'data')),
    subtype TEXT NOT NULL CHECK(length(subtype) > 0),
    strength INTEGER NOT NULL CHECK(strength BETWEEN -127 AND 0),
    source_address TEXT NOT NULL
        CHECK(length(source_address) = 32
              AND source_address NOT GLOB '*[^0-9a-f]*'),
    source_address_randomized INTEGER NOT NULL
        CHECK(source_address_randomized IN (0, 1)),
    channel INTEGER NOT NULL CHECK(channel BETWEEN 1 AND 14),
    sensor_name TEXT NOT NULL CHECK(length(sensor_name) > 0)
)
"""


class Packet(NamedTuple):
    timestamp: str
    type: str
    subtype: str
    strength: int
    source_address: str
    source_address_randomized: int
    channel: int
    sensor_name: str


def synthetic_identifier(
    role: str,
    *,
    deployment_id: str = TEST_DEPLOYMENT_ID,
    key: bytes = TEST_ONLY_HMAC_KEY,
) -> str:
    """Return a deployment-scoped HMAC pseudonym for a synthetic role.

    The input is a scenario label, not a MAC address.  The function models the
    maintained collector's deployment scoping and 128-bit output shape without
    creating or retaining any original-address mapping.
    """

    if len(key) != 32:
        raise ValueError("the synthetic HMAC test key must contain exactly 32 bytes")
    try:
        deployment_bytes = deployment_id.encode("ascii")
        role_bytes = role.encode("ascii")
    except UnicodeEncodeError as error:
        raise ValueError("deployment_id and role must contain ASCII only") from error
    if not deployment_bytes or len(deployment_bytes) > 65_535:
        raise ValueError("deployment_id must contain 1 through 65,535 ASCII bytes")
    if not role_bytes or len(role_bytes) > 65_535:
        raise ValueError("role must contain 1 through 65,535 ASCII bytes")

    message = b"\x00".join(
        (
            IDENTIFIER_DOMAIN,
            IDENTIFIER_SCHEME.encode("ascii"),
            IDENTIFIER_SCOPE.encode("ascii"),
        )
    )
    message += (
        b"\x00"
        + len(deployment_bytes).to_bytes(2, "big")
        + deployment_bytes
        + b"\x00"
        + len(role_bytes).to_bytes(2, "big")
        + role_bytes
    )
    return hmac.new(key, message, hashlib.sha256).digest()[:16].hex()


MOVING_RETAINED = synthetic_identifier("moving-retained")
STATIONARY_OVER_TWO_HOURS = synthetic_identifier("stationary-over-two-hours")
RANDOMIZED_VISITOR_A = synthetic_identifier("randomized-visitor-a")
RANDOMIZED_VISITOR_B = synthetic_identifier("randomized-visitor-b")
ACTIVITY_STAY_RETAINED = synthetic_identifier("activity-stay-retained")

IDENTIFIER_TO_ROLE = {
    MOVING_RETAINED: "moving-retained",
    STATIONARY_OVER_TWO_HOURS: "stationary-over-two-hours",
    RANDOMIZED_VISITOR_A: "randomized-visitor-a",
    RANDOMIZED_VISITOR_B: "randomized-visitor-b",
    ACTIVITY_STAY_RETAINED: "activity-stay-retained",
}


def _timestamp(second: int, microsecond: int) -> str:
    captured_at = BASE_TIME + timedelta(seconds=second, microseconds=microsecond)
    return captured_at.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _packet(
    *,
    second: int,
    microsecond: int,
    frame_type: str,
    subtype: str,
    strength: int,
    source_address: str,
    randomized: int,
    channel: int,
    sensor_name: str,
) -> Packet:
    return Packet(
        _timestamp(second, microsecond),
        frame_type,
        subtype,
        strength,
        source_address,
        randomized,
        channel,
        sensor_name,
    )


def fixture_packets() -> list[Packet]:
    """Create deterministic observations for the four documented roles."""

    rows: list[Packet] = []

    # A fixed, globally administered pseudonym remains at one sensor for
    # 7,500.5 seconds (>2 h). Two packets in each observed second exercise the
    # packet-to-one-second reduction without producing a huge fixture.
    for second in range(0, 7_501, 20):
        for microsecond, strength in ((110_000, -46), (610_000, -48)):
            rows.append(
                _packet(
                    second=second,
                    microsecond=microsecond,
                    frame_type="data",
                    subtype="qos-data",
                    strength=strength,
                    source_address=STATIONARY_OVER_TWO_HOURS,
                    randomized=0,
                    channel=1,
                    sensor_name=SENSOR_A,
                )
            )

    # A retained device moves from sensor A to sensor B over 160 seconds. A
    # short overlap gives the 20-second localization step detections at both
    # sensors while keeping the complete trajectory well below the 2 h cutoff.
    for second in range(160):
        primary_sensor = SENSOR_A if second < 80 else SENSOR_B
        primary_channel = 1 if primary_sensor == SENSOR_A else 11
        progress = second if second < 80 else second - 80
        primary_strength = -66 + min(progress, 35) // 7
        for microsecond, adjustment in ((120_000, 0), (720_000, -2)):
            rows.append(
                _packet(
                    second=second,
                    microsecond=microsecond,
                    frame_type="management",
                    subtype="probe-request",
                    strength=primary_strength + adjustment,
                    source_address=MOVING_RETAINED,
                    randomized=0,
                    channel=primary_channel,
                    sensor_name=primary_sensor,
                )
            )

        if 70 <= second < 90:
            overlap_sensor = SENSOR_B if primary_sensor == SENSOR_A else SENSOR_A
            overlap_channel = 11 if overlap_sensor == SENSOR_B else 1
            for microsecond, strength in ((240_000, -73), (840_000, -75)):
                rows.append(
                    _packet(
                        second=second,
                        microsecond=microsecond,
                        frame_type="management",
                        subtype="probe-request",
                        strength=strength,
                        source_address=MOVING_RETAINED,
                        randomized=0,
                        channel=overlap_channel,
                        sensor_name=overlap_sensor,
                    )
                )

    # The same retained identifier returns on the next Asia/Seoul calendar
    # day after a gap much longer than the five-minute session boundary. This
    # is a second short visit, not one continuous stationary session.
    for second in range(86_400, 86_440):
        visit_second = second - 86_400
        sensor_name = SENSOR_A if visit_second < 20 else SENSOR_B
        channel = 1 if sensor_name == SENSOR_A else 11
        for microsecond, strength in ((140_000, -62), (740_000, -64)):
            rows.append(
                _packet(
                    second=second,
                    microsecond=microsecond,
                    frame_type="management",
                    subtype="probe-request",
                    strength=strength,
                    source_address=MOVING_RETAINED,
                    randomized=0,
                    channel=channel,
                    sensor_name=sensor_name,
                )
            )

    # A non-randomized seven-minute presence survives cleaning but exceeds the
    # five-minute minimum used by the Activities example.
    for second in range(600, 1_021, 20):
        for microsecond, strength in ((160_000, -52), (760_000, -54)):
            rows.append(
                _packet(
                    second=second,
                    microsecond=microsecond,
                    frame_type="management",
                    subtype="probe-request",
                    strength=strength,
                    source_address=ACTIVITY_STAY_RETAINED,
                    randomized=0,
                    channel=11,
                    sensor_name=SENSOR_B,
                )
            )

    # Two locally administered/randomized examples are included so that the
    # Chapter 3 cleaning step can be tested at both sensors.
    for role, sensor_name, channel, start_second in (
        (RANDOMIZED_VISITOR_A, SENSOR_A, 1, 20),
        (RANDOMIZED_VISITOR_B, SENSOR_B, 11, 80),
    ):
        for second in range(start_second, start_second + 40):
            for microsecond, strength in ((330_000, -58), (930_000, -61)):
                rows.append(
                    _packet(
                        second=second,
                        microsecond=microsecond,
                        frame_type="management",
                        subtype="probe-request",
                        strength=strength,
                        source_address=role,
                        randomized=1,
                        channel=channel,
                        sensor_name=sensor_name,
                    )
                )

    return sorted(rows)


def _write_database(path: Path, packets: Iterable[Packet]) -> None:
    connection = sqlite3.connect(path)
    try:
        connection.execute("PRAGMA page_size = 4096")
        connection.execute("PRAGMA auto_vacuum = NONE")
        connection.execute("PRAGMA journal_mode = OFF")
        connection.execute("PRAGMA synchronous = OFF")
        connection.execute(f"PRAGMA user_version = {FIXTURE_VERSION}")
        connection.execute(CREATE_PACKETS_SQL)
        connection.executemany(
            "INSERT INTO packets VALUES (?, ?, ?, ?, ?, ?, ?, ?)", packets
        )
        connection.commit()
        connection.execute("VACUUM")
    finally:
        connection.close()

    # SQLite writes the library version that last modified the database into
    # header bytes 96--99. That field does not affect schema, rows, or database
    # behavior, but it otherwise makes identical fixtures differ across Python
    # runtimes. Pin it to the version used by the committed v2 fixture so the
    # byte-level artifact remains reproducible without changing its contents.
    with path.open("r+b") as handle:
        header = handle.read(100)
        if len(header) != 100 or not header.startswith(b"SQLite format 3\x00"):
            raise AssertionError("fixture builder did not create a valid SQLite header")
        handle.seek(96)
        handle.write((3_050_004).to_bytes(4, "big"))


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _role_aware_packet_contract_sha256(packets: Iterable[Packet]) -> str:
    """Hash packet values after replacing each pseudonym with its role label."""

    digest = hashlib.sha256()
    for packet in packets:
        values = list(packet)
        try:
            values[4] = IDENTIFIER_TO_ROLE[packet.source_address]
        except KeyError as error:
            raise ValueError("packet contains an unknown synthetic pseudonym") from error
        canonical_line = json.dumps(
            values, separators=(",", ":"), ensure_ascii=True
        ) + "\n"
        digest.update(canonical_line.encode("utf-8"))
    return digest.hexdigest()


def _write_sensor_metadata(path: Path) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(("sensor_name", "x", "y", "coordinate_system", "is_synthetic"))
        writer.writerow((SENSOR_A, "0.0", "0.0", "local_cartesian_metres", "1"))
        writer.writerow((SENSOR_B, "75.0", "0.0", "local_cartesian_metres", "1"))


def _sessions(
    timestamps: list[datetime], gap_seconds: int = 300
) -> list[list[datetime]]:
    sessions: list[list[datetime]] = []
    for captured_at in sorted(timestamps):
        if (
            not sessions
            or (captured_at - sessions[-1][-1]).total_seconds() > gap_seconds
        ):
            sessions.append([captured_at])
        else:
            sessions[-1].append(captured_at)
    return sessions


def _manifest(
    database_path: Path, sensor_metadata_path: Path, packets: list[Packet]
) -> dict[str, object]:
    moving_times = [
        datetime.strptime(row.timestamp, "%Y-%m-%dT%H:%M:%S.%fZ").replace(
            tzinfo=timezone.utc
        )
        for row in packets
        if row.source_address == MOVING_RETAINED
    ]
    stationary_times = [
        datetime.strptime(row.timestamp, "%Y-%m-%dT%H:%M:%S.%fZ").replace(
            tzinfo=timezone.utc
        )
        for row in packets
        if row.source_address == STATIONARY_OVER_TWO_HOURS
    ]
    activity_times = [
        datetime.strptime(row.timestamp, "%Y-%m-%dT%H:%M:%S.%fZ").replace(
            tzinfo=timezone.utc
        )
        for row in packets
        if row.source_address == ACTIVITY_STAY_RETAINED
    ]
    moving_sessions = _sessions(moving_times)

    role_aware_digest = _role_aware_packet_contract_sha256(packets)
    if role_aware_digest != ROLE_AWARE_PACKET_CONTRACT_SHA256:
        raise AssertionError(
            "synthetic packet values or role assignments changed: "
            f"expected {ROLE_AWARE_PACKET_CONTRACT_SHA256}, found {role_aware_digest}"
        )

    return {
        "database": DATABASE_NAME,
        "database_sha256": _sha256(database_path),
        "fixture_version": FIXTURE_VERSION,
        "identifier_contract": {
            "algorithm": IDENTIFIER_ALGORITHM,
            "deployment_id": TEST_DEPLOYMENT_ID,
            "input_kind": "fully synthetic scenario role labels; not MAC addresses",
            "public_test_key_hex": TEST_ONLY_HMAC_KEY_HEX,
            "key_is_public": True,
            "key_is_secret": False,
            "key_is_test_only": True,
            "key_must_not_be_used_for_field_collection": True,
            "lowercase_hex_characters": 32,
            "scheme": IDENTIFIER_SCHEME,
            "security_notice": (
                "PUBLIC TEST KEY; never use this value for field collection"
            ),
            "scope": IDENTIFIER_SCOPE,
            "within_deployment_linkage": (
                "the same synthetic role has the same pseudonym across sensors and dates"
            ),
            "cross_deployment_linkage": (
                "changing the deployment identifier or HMAC key changes the pseudonym"
            ),
        },
        "fixture_scope": {
            "minimal_packets_fixture": True,
            "no_hardware_capture_occurred": True,
            "operational_loss_counters_fabricated": False,
            "omitted_operational_tables": {
                "capture_interface_summary": (
                    "omitted because no hardware capture occurred"
                ),
                "capture_metadata": "omitted because no hardware capture occurred",
            },
        },
        "metric_smoke_test_roles": {
            "Activities": "activity_stay_retained",
            "Count": "all non-stationary scenarios",
            "Location": "moving_retained sensor overlap",
            "Revisits": "moving_retained local_calendar_dates",
            "Track": "moving_retained sensor transition",
        },
        "packet_columns": list(PACKET_COLUMNS),
        "privacy_boundary": {
            "bssids_stored": False,
            "destination_addresses_stored": False,
            "frame_bytes_stored": False,
            "fully_synthetic": True,
            "identifiers_derived_only_from_scenario_labels": True,
            "mac_addresses_used_as_identifier_inputs": False,
            "original_address_mapping_exists": False,
            "packet_payloads_stored": False,
            "raw_mac_addresses_stored": False,
            "ssids_stored": False,
        },
        "row_count": len(packets),
        "role_aware_packet_contract_sha256": role_aware_digest,
        "role_aware_packet_contract_definition": (
            "SHA-256 over insertion-order JSON packet rows after replacing "
            "source_address with its synthetic scenario role"
        ),
        "sensor_metadata": SENSOR_METADATA_NAME,
        "sensor_metadata_sha256": _sha256(sensor_metadata_path),
        "scenarios": {
            "activity_stay_retained": {
                "identifier": ACTIVITY_STAY_RETAINED,
                "randomized": 0,
                "sensors": [SENSOR_B],
                "span_seconds": (
                    max(activity_times) - min(activity_times)
                ).total_seconds(),
            },
            "moving_retained": {
                "identifier": MOVING_RETAINED,
                "local_calendar_dates": sorted(
                    {
                        captured_at.astimezone(LOCAL_TIMEZONE).date().isoformat()
                        for captured_at in moving_times
                    }
                ),
                "longest_session_seconds": max(
                    (session[-1] - session[0]).total_seconds()
                    for session in moving_sessions
                ),
                "randomized": 0,
                "sensors": [SENSOR_A, SENSOR_B],
            },
            "randomized_visitors": {
                "identifiers": [RANDOMIZED_VISITOR_A, RANDOMIZED_VISITOR_B],
                "randomized": 1,
                "sensors": [SENSOR_A, SENSOR_B],
            },
            "stationary_over_two_hours": {
                "identifier": STATIONARY_OVER_TWO_HOURS,
                "randomized": 0,
                "sensors": [SENSOR_A],
                "span_seconds": (
                    max(stationary_times) - min(stationary_times)
                ).total_seconds(),
            },
        },
        "sensors": [SENSOR_A, SENSOR_B],
        "synthetic_coordinate_system": "local Cartesian metres; no geographic origin",
        "time_zone_for_local_calendar": "Asia/Seoul (UTC+09:00; no DST)",
        "time_range_utc": [packets[0].timestamp, packets[-1].timestamp],
    }


def build_fixture(output_dir: Path) -> tuple[Path, Path, Path]:
    """Atomically rebuild the database and manifest in ``output_dir``."""

    output_dir.mkdir(parents=True, exist_ok=True)
    database_path = output_dir / DATABASE_NAME
    manifest_path = output_dir / MANIFEST_NAME
    sensor_metadata_path = output_dir / SENSOR_METADATA_NAME
    temporary_database = output_dir / f".{DATABASE_NAME}.tmp"
    temporary_manifest = output_dir / f".{MANIFEST_NAME}.tmp"
    temporary_sensor_metadata = output_dir / f".{SENSOR_METADATA_NAME}.tmp"
    temporary_database.unlink(missing_ok=True)
    temporary_manifest.unlink(missing_ok=True)
    temporary_sensor_metadata.unlink(missing_ok=True)

    packets = fixture_packets()
    try:
        _write_database(temporary_database, packets)
        _write_sensor_metadata(temporary_sensor_metadata)
        manifest = _manifest(temporary_database, temporary_sensor_metadata, packets)
        temporary_manifest.write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
            newline="\n",
        )
        os.replace(temporary_database, database_path)
        os.replace(temporary_sensor_metadata, sensor_metadata_path)
        os.replace(temporary_manifest, manifest_path)
    finally:
        temporary_database.unlink(missing_ok=True)
        temporary_manifest.unlink(missing_ok=True)
        temporary_sensor_metadata.unlink(missing_ok=True)

    return database_path, manifest_path, sensor_metadata_path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent,
        help="directory for the SQLite fixture and manifest (default: script directory)",
    )
    args = parser.parse_args()
    database_path, manifest_path, sensor_metadata_path = build_fixture(
        args.output_dir.resolve()
    )
    print(f"wrote {database_path}")
    print(f"wrote {manifest_path}")
    print(f"wrote {sensor_metadata_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
