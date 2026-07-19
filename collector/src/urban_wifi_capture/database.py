"""SQLite schema and batched writer for pseudonymized packet records."""

from __future__ import annotations

import os
import queue
import re
import sqlite3
import stat
import time
from pathlib import Path
from typing import Iterable, List, Optional

from . import __version__
from .identifiers import (
    DEPLOYMENT_ID_RE,
    IDENTIFIER_ALGORITHM,
    IDENTIFIER_HEX_LENGTH,
    IDENTIFIER_SCHEME,
    IDENTIFIER_SCOPE,
)
from .model import CaptureSummary, PacketRecord

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
CREATE TABLE IF NOT EXISTS packets (
    timestamp TEXT NOT NULL
        CHECK (timestamp GLOB '????-??-??T??:??:??*Z'),
    type TEXT NOT NULL
        CHECK (type IN ('management', 'data')),
    subtype TEXT NOT NULL
        CHECK (length(subtype) > 0),
    strength INTEGER NOT NULL
        CHECK (strength BETWEEN -127 AND 0),
    source_address TEXT NOT NULL
        CHECK (
            length(source_address) = 32
            AND source_address = lower(source_address)
            AND source_address NOT GLOB '*[^0-9a-f]*'
        ),
    source_address_randomized INTEGER NOT NULL
        CHECK (source_address_randomized IN (0, 1)),
    channel INTEGER NOT NULL
        CHECK (channel BETWEEN 1 AND 14),
    sensor_name TEXT NOT NULL
        CHECK (
            length(sensor_name) BETWEEN 1 AND 32
            AND sensor_name NOT GLOB '*[^A-Za-z0-9_-]*'
        )
)
"""

CREATE_METADATA_SQL = """
CREATE TABLE IF NOT EXISTS capture_metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
)
"""

CREATE_SUMMARY_SQL = """
CREATE TABLE IF NOT EXISTS capture_interface_summary (
    interface TEXT PRIMARY KEY,
    channel INTEGER NOT NULL CHECK (channel BETWEEN 1 AND 14),
    pcap_received INTEGER NOT NULL CHECK (pcap_received >= -1),
    pcap_dropped INTEGER NOT NULL CHECK (pcap_dropped >= -1),
    interface_dropped INTEGER NOT NULL CHECK (interface_dropped >= -1),
    queue_dropped INTEGER NOT NULL CHECK (queue_dropped >= 0),
    records_emitted INTEGER NOT NULL CHECK (records_emitted >= 0),
    records_filtered INTEGER NOT NULL CHECK (records_filtered >= 0),
    completed_at TEXT NOT NULL CHECK (completed_at GLOB '????-??-??T??:??:??*Z')
)
"""

INSERT_SUMMARY_SQL = """
INSERT OR REPLACE INTO capture_interface_summary (
    interface, channel, pcap_received, pcap_dropped,
    interface_dropped, queue_dropped, records_emitted, records_filtered, completed_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
"""

INSERT_SQL = """
INSERT INTO packets (
    timestamp, type, subtype, strength, source_address,
    source_address_randomized, channel, sensor_name
) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
"""

BASE_METADATA = {
    "schema_version": "2",
    "timestamp_timezone": "UTC",
    "identifier_algorithm": IDENTIFIER_ALGORITHM,
    "identifier_scheme": IDENTIFIER_SCHEME,
    "identifier_scope": IDENTIFIER_SCOPE,
    "identifier_hex_length": str(IDENTIFIER_HEX_LENGTH),
    "randomized_rule": "locally-administered-bit-before-pseudonymization",
    "raw_frames_stored": "false",
    "raw_addresses_stored": "false",
    "ssid_stored": "false",
    "bssid_stored": "false",
    "destination_address_stored": "false",
    "bluetooth_stored": "false",
    "cloud_upload_enabled": "false",
    "capture_loss_summary_stored": "true",
    "data_frame_direction": "direct-or-to-ds-transmitter-only",
    "software_version": __version__,
}


def metadata_for_deployment(deployment_id: str) -> dict[str, str]:
    """Return public run metadata; the secret key and derivatives are excluded."""

    if type(deployment_id) is not str or not DEPLOYMENT_ID_RE.fullmatch(deployment_id):
        raise ValueError("deployment_id must be a validated opaque ASCII code")
    return {**BASE_METADATA, "deployment_id": deployment_id}


class SchemaMismatchError(RuntimeError):
    """Raised when an existing database does not match the public contract."""


def _ensure_private_directory(path: Path) -> None:
    try:
        details = path.lstat()
    except FileNotFoundError as exc:
        raise PermissionError(f"database directory must be pre-created: {path}") from exc
    if stat.S_ISLNK(details.st_mode) or not stat.S_ISDIR(details.st_mode):
        raise PermissionError(f"database directory must be a real directory: {path}")
    if os.name == "posix":
        if details.st_uid != os.geteuid():
            raise PermissionError(f"database directory must be owned by the service user: {path}")
        if stat.S_IMODE(details.st_mode) != 0o700:
            raise PermissionError(f"database directory mode must be 0700: {path}")


def _open_private_database_file(path: Path) -> bool:
    if path.is_symlink():
        raise PermissionError(f"database path must not be a symlink: {path}")
    try:
        details = path.lstat()
    except FileNotFoundError:
        flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags, 0o600)
        os.close(descriptor)
        return True

    if not stat.S_ISREG(details.st_mode) or details.st_nlink != 1:
        raise PermissionError(f"database path must be a single regular file: {path}")
    if os.name == "posix":
        if details.st_uid != os.geteuid():
            raise PermissionError(f"database file must be owned by the service user: {path}")
        if stat.S_IMODE(details.st_mode) != 0o600:
            raise PermissionError(f"database file mode must be 0600: {path}")
    return False


def _reject_symlinked_parents(path: Path) -> None:
    for candidate in (path.parent, *path.parent.parents):
        if candidate.is_symlink():
            raise PermissionError(f"database path contains a symlinked directory: {candidate}")


def _normalized_schema(sql: str) -> str:
    value = re.sub(r"\s+", " ", sql.strip()).lower()
    return value.replace("create table if not exists", "create table", 1)


def _validate_existing_database(
    connection: sqlite3.Connection,
    expected_metadata: dict[str, str],
) -> None:
    tables = {
        row[0]
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        )
    }
    expected_tables = {"packets", "capture_metadata", "capture_interface_summary"}
    if tables != expected_tables:
        raise SchemaMismatchError(
            f"existing database tables {sorted(tables)!r} do not match the capture contract"
        )

    expected_sql = {
        "packets": CREATE_PACKETS_SQL,
        "capture_metadata": CREATE_METADATA_SQL,
        "capture_interface_summary": CREATE_SUMMARY_SQL,
    }
    for table, create_sql in expected_sql.items():
        stored = connection.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name=?", (table,)
        ).fetchone()
        if stored is None or _normalized_schema(stored[0]) != _normalized_schema(create_sql):
            raise SchemaMismatchError(f"existing {table} schema does not match schema version 2")

    columns = tuple(row[1] for row in connection.execute("PRAGMA table_info(packets)"))
    if columns != PACKET_COLUMNS:
        raise SchemaMismatchError(
            f"existing packets schema {columns!r} does not match {PACKET_COLUMNS!r}"
        )
    actual_metadata = dict(connection.execute("SELECT key, value FROM capture_metadata"))
    if actual_metadata != expected_metadata:
        raise SchemaMismatchError(
            "existing capture metadata does not match this schema version and deployment"
        )


def connect_database(path: Path, deployment_id: str) -> sqlite3.Connection:
    # ``absolute`` normalizes dot segments without following symlinks. Calling
    # ``resolve`` here would erase the evidence needed by the lstat checks.
    path = Path(path).absolute()
    _reject_symlinked_parents(path)
    _ensure_private_directory(path.parent)
    created = _open_private_database_file(path)
    connection = sqlite3.connect(f"{path.as_uri()}?mode=rw", timeout=30.0, uri=True)
    expected_metadata = metadata_for_deployment(deployment_id)
    try:
        if created:
            connection.execute("PRAGMA journal_mode = WAL")
            connection.execute("PRAGMA synchronous = FULL")
            connection.execute(CREATE_PACKETS_SQL)
            connection.execute(CREATE_METADATA_SQL)
            connection.execute(CREATE_SUMMARY_SQL)
            connection.executemany(
                "INSERT INTO capture_metadata (key, value) VALUES (?, ?)",
                sorted(expected_metadata.items()),
            )
            connection.commit()
        else:
            _validate_existing_database(connection, expected_metadata)
            connection.execute("PRAGMA journal_mode = WAL")
            connection.execute("PRAGMA synchronous = FULL")
    except Exception:
        connection.close()
        raise
    return connection


def insert_records(connection: sqlite3.Connection, records: Iterable[PacketRecord]) -> int:
    rows = [record.as_tuple() for record in records]
    if not rows:
        return 0
    connection.executemany(INSERT_SQL, rows)
    connection.commit()
    return len(rows)


def writer_loop(
    database_path: Path,
    record_queue: object,
    batch_size: int,
    producer_count: int = 1,
    flush_interval: float = 1.0,
    *,
    deployment_id: str,
) -> None:
    """Drain SQLite until one FIFO completion marker arrives per producer."""

    if producer_count < 1:
        raise ValueError("producer_count must be positive")
    if flush_interval <= 0:
        raise ValueError("flush_interval must be positive")

    connection = connect_database(Path(database_path), deployment_id)
    batch: List[PacketRecord] = []
    next_flush: Optional[float] = None
    completed_producers = 0
    try:
        while True:
            timeout = (
                flush_interval if next_flush is None else max(0.0, next_flush - time.monotonic())
            )
            try:
                item: Optional[object] = record_queue.get(timeout=timeout)  # type: ignore[attr-defined]
            except queue.Empty:
                if batch:
                    insert_records(connection, batch)
                    batch.clear()
                next_flush = None
                continue
            if item is None:
                completed_producers += 1
                if completed_producers == producer_count:
                    break
                continue
            if isinstance(item, CaptureSummary):
                if batch:
                    insert_records(connection, batch)
                    batch.clear()
                next_flush = None
                connection.execute(INSERT_SUMMARY_SQL, item.as_tuple())
                connection.commit()
                continue
            if not isinstance(item, PacketRecord):
                raise TypeError("writer queue accepted an unsupported value")
            if not batch:
                next_flush = time.monotonic() + flush_interval
            batch.append(item)
            if len(batch) >= batch_size or (
                next_flush is not None and time.monotonic() >= next_flush
            ):
                insert_records(connection, batch)
                batch.clear()
                next_flush = None
        if batch:
            insert_records(connection, batch)
    finally:
        connection.close()
