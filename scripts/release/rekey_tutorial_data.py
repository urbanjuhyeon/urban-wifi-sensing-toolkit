#!/usr/bin/env python3
"""Build, verify, and apply 32-hex HMAC pseudonyms to field-derived tutorial data.

The script keeps four release scopes separate: the Chapter 3 location and
Track tutorials, the campus metrics sample, and the GPS-linked campus location
sample. The Chapter 3 processing walkthrough is fully synthetic and is built
by ``scripts/pipeline/build_synthetic_tutorial_archive.py`` instead. A
different private 32-byte key is required for each field-derived scope. Keys
are read only during the build and are never printed, copied, fingerprinted,
or written to the candidate.
"""

from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import hmac
import json
import os
import re
import shutil
import sqlite3
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable
from itertools import zip_longest

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq


ALGORITHM = "hmac-sha256-128-v1"
DOMAIN = b"urban-wifi-tutorial-public-handoff-v1\x00"
HEX32 = re.compile(r"^[0-9a-f]{32}$")
KEY_BYTES = 32

IDENTIFIER_COLUMNS = {
    "source_address",
    "destination_address",
    "access_point_address",
    "device_address",
    "mac_address",
}

TARGETS: dict[str, tuple[str, ...]] = {
    "ch3-location-tutorial": (
        "workflow/ch3_tutorial/sample_location.zip",
        "workflow/ch3_tutorial/sample_wifi.csv",
    ),
    "ch3-track-tutorial": (
        "workflow/ch3_tutorial/sample_track.parquet",
        "workflow/ch3_tutorial/sample_track.zip",
    ),
    "campus-metrics-sample": (
        "workflow/unist19_main/data/sample_main.zip",
    ),
    "campus-location-sample": (
        "workflow/unist19_loc/data/gps.csv",
        "workflow/unist19_loc/data/sample_loc.zip",
        "workflow/unist19_loc/data/wifi.parquet",
    ),
}


class RekeyError(RuntimeError):
    """Raised when a candidate cannot be built without changing its contract."""


def _quoted(identifier: str) -> str:
    return '"' + identifier.replace('"', '""') + '"'


def _identifier_columns(names: Iterable[str]) -> list[str]:
    return [name for name in names if name.lower() in IDENTIFIER_COLUMNS]


def _canonical(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip().lower()


def _public_pseudonym(key: bytes, scope: str, value: Any) -> str:
    canonical = _canonical(value)
    if not canonical:
        return canonical
    message = DOMAIN + scope.encode("ascii") + b"\x00" + canonical.encode("utf-8")
    return hmac.new(key, message, hashlib.sha256).hexdigest()[:32]


def _read_key(path: Path) -> bytes:
    lexical = Path(os.path.abspath(os.fspath(path.expanduser())))
    if lexical.is_symlink():
        raise RekeyError(f"key must not be a symlink: {lexical}")
    path = lexical.resolve(strict=True)
    if not path.is_file():
        raise RekeyError(f"key must be a regular file: {path}")
    repository_root = Path(__file__).resolve().parents[2]
    try:
        path.relative_to(repository_root)
    except ValueError:
        pass
    else:
        raise RekeyError(f"release key must remain outside the repository: {path}")
    key = path.read_bytes()
    if len(key) != KEY_BYTES:
        raise RekeyError(f"key must contain exactly {KEY_BYTES} raw bytes: {path}")
    return key


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _length_counts(values: Iterable[Any]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for value in values:
        canonical = _canonical(value)
        label = "null-or-empty" if not canonical else str(len(canonical))
        counts[label] = counts.get(label, 0) + 1
    return dict(sorted(counts.items()))


def _audit_parquet(path: Path, location: str) -> list[dict[str, Any]]:
    table = pq.read_table(path)
    records: list[dict[str, Any]] = []
    for name in _identifier_columns(table.column_names):
        values = pc.unique(table[name]).to_pylist()
        records.append(
            {
                "location": f"{location}::{name}",
                "rows": table.num_rows,
                "unique": len(values),
                "lengths": _length_counts(values),
                "all_32_hex": all(HEX32.fullmatch(_canonical(v)) for v in values if v is not None),
            }
        )
    return records


def _audit_csv(path: Path, location: str) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            return []
        columns = _identifier_columns(reader.fieldnames)
        values = {name: set() for name in columns}
        rows = 0
        for row in reader:
            rows += 1
            for name in columns:
                values[name].add(_canonical(row.get(name)))
    return [
        {
            "location": f"{location}::{name}",
            "rows": rows,
            "unique": len(items),
            "lengths": _length_counts(items),
            "all_32_hex": all(HEX32.fullmatch(item) for item in items if item),
        }
        for name, items in values.items()
    ]


def _audit_sqlite(path: Path, location: str) -> list[dict[str, Any]]:
    connection = sqlite3.connect(f"file:{path.as_posix()}?mode=ro", uri=True)
    try:
        records: list[dict[str, Any]] = []
        tables = [
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
            )
        ]
        for table in tables:
            names = [row[1] for row in connection.execute(f"PRAGMA table_info({_quoted(table)})")]
            for name in _identifier_columns(names):
                values = [
                    row[0]
                    for row in connection.execute(
                        f"SELECT DISTINCT {_quoted(name)} FROM {_quoted(table)}"
                    )
                ]
                rows = connection.execute(f"SELECT count(*) FROM {_quoted(table)}").fetchone()[0]
                records.append(
                    {
                        "location": f"{location}::{table}.{name}",
                        "rows": rows,
                        "unique": len(values),
                        "lengths": _length_counts(values),
                        "all_32_hex": all(
                            HEX32.fullmatch(_canonical(v)) for v in values if v is not None
                        ),
                    }
                )
        return records
    finally:
        connection.close()


def _audit_zip(path: Path, location: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    with tempfile.TemporaryDirectory(prefix="tutorial-zip-audit-") as temp_name:
        temp = Path(temp_name)
        with zipfile.ZipFile(path, "r") as archive:
            archive.extractall(temp)
        for member in sorted(p for p in temp.rglob("*") if p.is_file()):
            relative = member.relative_to(temp).as_posix()
            records.extend(_audit_file(member, f"{location}::{relative}"))
    return records


def _audit_file(path: Path, location: str) -> list[dict[str, Any]]:
    suffix = path.suffix.lower()
    if suffix == ".parquet":
        return _audit_parquet(path, location)
    if suffix == ".csv":
        return _audit_csv(path, location)
    if suffix in {".sqlite", ".sqlite3", ".db"}:
        return _audit_sqlite(path, location)
    if suffix == ".zip":
        return _audit_zip(path, location)
    return []


def _collect_identifiers(path: Path) -> set[str]:
    suffix = path.suffix.lower()
    values: set[str] = set()
    if suffix == ".parquet":
        table = pq.read_table(path)
        for name in _identifier_columns(table.column_names):
            values.update(_canonical(value) for value in pc.unique(table[name]).to_pylist())
    elif suffix == ".csv":
        with path.open("r", encoding="utf-8-sig", newline="") as handle:
            reader = csv.DictReader(handle)
            if reader.fieldnames:
                columns = _identifier_columns(reader.fieldnames)
                for row in reader:
                    values.update(_canonical(row.get(name)) for name in columns)
    elif suffix in {".sqlite", ".sqlite3", ".db"}:
        connection = sqlite3.connect(f"file:{path.as_posix()}?mode=ro", uri=True)
        try:
            tables = [
                row[0]
                for row in connection.execute(
                    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
                )
            ]
            for table in tables:
                names = [row[1] for row in connection.execute(f"PRAGMA table_info({_quoted(table)})")]
                for name in _identifier_columns(names):
                    values.update(
                        _canonical(row[0])
                        for row in connection.execute(
                            f"SELECT DISTINCT {_quoted(name)} FROM {_quoted(table)}"
                        )
                    )
        finally:
            connection.close()
    elif suffix == ".zip":
        with tempfile.TemporaryDirectory(prefix="tutorial-zip-identifiers-") as temp_name:
            temp = Path(temp_name)
            with zipfile.ZipFile(path, "r") as archive:
                archive.extractall(temp)
            for member in (item for item in temp.rglob("*") if item.is_file()):
                values.update(_collect_identifiers(member))
    values.discard("")
    return values


def _map_values(values: Iterable[Any], key: bytes, scope: str) -> dict[str, str]:
    canonical_values = {_canonical(value) for value in values if _canonical(value)}
    mapping = {value: _public_pseudonym(key, scope, value) for value in canonical_values}
    if len(set(mapping.values())) != len(mapping):
        raise RekeyError(f"HMAC collision within {scope}")
    return mapping


def _rekey_parquet(source: Path, target: Path, key: bytes, scope: str) -> None:
    table = pq.read_table(source)
    for name in _identifier_columns(table.column_names):
        index = table.schema.get_field_index(name)
        field = table.schema.field(index)
        array = table[name].combine_chunks()
        encoded = pc.dictionary_encode(array)
        dictionary = encoded.dictionary.to_pylist()
        mapping = _map_values(dictionary, key, scope)
        replaced = pa.array(
            [mapping.get(_canonical(value), _canonical(value)) for value in dictionary],
            type=pa.string(),
        )
        expanded = pc.take(replaced, encoded.indices)
        new_field = pa.field(name, pa.string(), nullable=field.nullable, metadata=field.metadata)
        table = table.set_column(index, new_field, expanded)
    target.parent.mkdir(parents=True, exist_ok=True)
    pq.write_table(table, target, compression="zstd")


def _rekey_csv(source: Path, target: Path, key: bytes, scope: str) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    with source.open("r", encoding="utf-8-sig", newline="") as input_handle:
        reader = csv.DictReader(input_handle)
        if reader.fieldnames is None:
            shutil.copy2(source, target)
            return
        fields = list(reader.fieldnames)
        columns = _identifier_columns(fields)
        with target.open("w", encoding="utf-8", newline="") as output_handle:
            writer = csv.DictWriter(output_handle, fieldnames=fields, lineterminator="\n")
            writer.writeheader()
            for row in reader:
                for name in columns:
                    row[name] = _public_pseudonym(key, scope, row.get(name))
                writer.writerow(row)


def _rekey_sqlite(source: Path, target: Path, key: bytes, scope: str) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    connection = sqlite3.connect(target)
    try:
        tables = [
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
            )
        ]
        for table in tables:
            names = [row[1] for row in connection.execute(f"PRAGMA table_info({_quoted(table)})")]
            for name in _identifier_columns(names):
                values = [
                    row[0]
                    for row in connection.execute(
                        f"SELECT DISTINCT {_quoted(name)} FROM {_quoted(table)}"
                    )
                    if row[0] is not None and _canonical(row[0])
                ]
                mapping = _map_values(values, key, scope)
                connection.execute("DROP TABLE IF EXISTS temp._tutorial_id_map")
                connection.execute(
                    "CREATE TEMP TABLE _tutorial_id_map(old_value TEXT PRIMARY KEY, new_value TEXT UNIQUE)"
                )
                connection.executemany(
                    "INSERT INTO _tutorial_id_map(old_value,new_value) VALUES (?,?)",
                    sorted(mapping.items()),
                )
                connection.execute(
                    f"UPDATE {_quoted(table)} SET {_quoted(name)} = "
                    f"(SELECT new_value FROM _tutorial_id_map "
                    f" WHERE old_value = lower(trim({_quoted(table)}.{_quoted(name)}))) "
                    f"WHERE lower(trim({_quoted(name)})) IN (SELECT old_value FROM _tutorial_id_map)"
                )
                connection.execute("DROP TABLE temp._tutorial_id_map")
        connection.commit()
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise RekeyError(f"SQLite integrity check failed for {source}: {integrity}")
        connection.execute("VACUUM")
    finally:
        connection.close()


def _write_deterministic_zip(source_dir: Path, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(
        target, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
    ) as archive:
        for path in sorted(p for p in source_dir.rglob("*") if p.is_file()):
            relative = path.relative_to(source_dir).as_posix()
            info = zipfile.ZipInfo(relative, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def _rekey_zip(source: Path, target: Path, key: bytes, scope: str) -> None:
    with tempfile.TemporaryDirectory(prefix="tutorial-zip-rekey-") as temp_name:
        temp = Path(temp_name)
        extracted = temp / "source"
        transformed = temp / "target"
        with zipfile.ZipFile(source, "r") as archive:
            archive.extractall(extracted)
        for path in sorted(p for p in extracted.rglob("*") if p.is_file()):
            relative = path.relative_to(extracted)
            _rekey_file(path, transformed / relative, key, scope)
        _write_deterministic_zip(transformed, target)


def _rekey_file(source: Path, target: Path, key: bytes, scope: str) -> None:
    suffix = source.suffix.lower()
    if suffix == ".parquet":
        _rekey_parquet(source, target, key, scope)
    elif suffix == ".csv":
        _rekey_csv(source, target, key, scope)
    elif suffix in {".sqlite", ".sqlite3", ".db"}:
        _rekey_sqlite(source, target, key, scope)
    elif suffix == ".zip":
        _rekey_zip(source, target, key, scope)
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def _normalized_audit(records: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {record["location"]: record for record in records}


def _compare_audits(
    before: list[dict[str, Any]], after: list[dict[str, Any]], relative: str
) -> None:
    before_map = _normalized_audit(before)
    after_map = _normalized_audit(after)
    if set(before_map) != set(after_map):
        raise RekeyError(f"identifier-bearing objects changed in {relative}")
    if not after_map:
        raise RekeyError(f"target contains no recognized identifier column: {relative}")
    for location, old in before_map.items():
        new = after_map[location]
        if old["rows"] != new["rows"] or old["unique"] != new["unique"]:
            raise RekeyError(f"row or unique-identifier count changed at {location}")
        if not new["all_32_hex"] or set(new["lengths"]) - {"32", "null-or-empty"}:
            raise RekeyError(f"candidate is not uniformly 32-hex at {location}")


def _compare_parquet_non_identifiers(source: Path, target: Path) -> None:
    before = pq.read_table(source)
    after = pq.read_table(target)
    if before.column_names != after.column_names or before.num_rows != after.num_rows:
        raise RekeyError(f"Parquet shape changed: {source}")
    if not before.schema.equals(after.schema, check_metadata=True):
        raise RekeyError(f"Parquet schema or metadata changed: {source}")
    for name in before.column_names:
        if name not in _identifier_columns((name,)) and not before[name].equals(after[name]):
            raise RekeyError(f"non-identifier Parquet values changed: {source}::{name}")


def _compare_csv_non_identifiers(source: Path, target: Path) -> None:
    with source.open("r", encoding="utf-8-sig", newline="") as left_handle, target.open(
        "r", encoding="utf-8-sig", newline=""
    ) as right_handle:
        left = csv.DictReader(left_handle)
        right = csv.DictReader(right_handle)
        if left.fieldnames != right.fieldnames or left.fieldnames is None:
            raise RekeyError(f"CSV header changed: {source}")
        keep = [name for name in left.fieldnames if name not in _identifier_columns((name,))]
        for row_number, (old, new) in enumerate(zip_longest(left, right), start=2):
            if old is None or new is None:
                raise RekeyError(f"CSV row count changed: {source}")
            if any(old[name] != new[name] for name in keep):
                raise RekeyError(f"non-identifier CSV value changed: {source}:{row_number}")


def _compare_sqlite_non_identifiers(source: Path, target: Path) -> None:
    left = sqlite3.connect(f"file:{source.as_posix()}?mode=ro", uri=True)
    right = sqlite3.connect(f"file:{target.as_posix()}?mode=ro", uri=True)
    try:
        query = "SELECT name,sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        left_tables = left.execute(query).fetchall()
        right_tables = right.execute(query).fetchall()
        if left_tables != right_tables:
            raise RekeyError(f"SQLite table schema changed: {source}")
        for table, _ in left_tables:
            columns = [row[1] for row in left.execute(f"PRAGMA table_info({_quoted(table)})")]
            keep = [name for name in columns if name not in _identifier_columns((name,))]
            if keep:
                select = ",".join(_quoted(name) for name in keep)
                old_cursor = left.execute(f"SELECT {select} FROM {_quoted(table)} ORDER BY rowid")
                new_cursor = right.execute(f"SELECT {select} FROM {_quoted(table)} ORDER BY rowid")
                while True:
                    old_rows = old_cursor.fetchmany(4096)
                    new_rows = new_cursor.fetchmany(4096)
                    if old_rows != new_rows:
                        raise RekeyError(f"non-identifier SQLite values changed: {source}::{table}")
                    if not old_rows:
                        break
            else:
                old_count = left.execute(f"SELECT count(*) FROM {_quoted(table)}").fetchone()[0]
                new_count = right.execute(f"SELECT count(*) FROM {_quoted(table)}").fetchone()[0]
                if old_count != new_count:
                    raise RekeyError(f"SQLite row count changed: {source}::{table}")
    finally:
        left.close()
        right.close()


def _compare_zip_non_identifiers(source: Path, target: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="tutorial-zip-compare-") as temp_name:
        temp = Path(temp_name)
        left_root = temp / "left"
        right_root = temp / "right"
        with zipfile.ZipFile(source, "r") as archive:
            left_names = sorted(name for name in archive.namelist() if not name.endswith("/"))
            archive.extractall(left_root)
        with zipfile.ZipFile(target, "r") as archive:
            right_names = sorted(name for name in archive.namelist() if not name.endswith("/"))
            archive.extractall(right_root)
        if left_names != right_names:
            raise RekeyError(f"ZIP member allowlist changed: {source}")
        for name in left_names:
            _compare_non_identifiers(left_root / name, right_root / name)


def _compare_non_identifiers(source: Path, target: Path) -> None:
    suffix = source.suffix.lower()
    if suffix == ".parquet":
        _compare_parquet_non_identifiers(source, target)
    elif suffix == ".csv":
        _compare_csv_non_identifiers(source, target)
    elif suffix in {".sqlite", ".sqlite3", ".db"}:
        _compare_sqlite_non_identifiers(source, target)
    elif suffix == ".zip":
        _compare_zip_non_identifiers(source, target)
    elif source.read_bytes() != target.read_bytes():
        raise RekeyError(f"non-data file bytes changed: {source}")


def _target_entries(root: Path) -> list[tuple[str, str, Path]]:
    entries: list[tuple[str, str, Path]] = []
    for scope, relatives in TARGETS.items():
        for relative in relatives:
            path = root / relative
            if not path.is_file():
                raise RekeyError(f"missing target: {path}")
            entries.append((scope, relative, path))
    return entries


def build_candidate(args: argparse.Namespace) -> int:
    root = args.repository_root.resolve(strict=True)
    output = args.output.resolve()
    if output.exists():
        raise RekeyError(f"refusing existing candidate directory: {output}")
    output.mkdir(parents=True)
    keys = {
        "ch3-location-tutorial": _read_key(args.ch3_location_key_file),
        "ch3-track-tutorial": _read_key(args.ch3_track_key_file),
        "campus-metrics-sample": _read_key(args.main_key_file),
        "campus-location-sample": _read_key(args.location_key_file),
    }
    if len(set(keys.values())) != len(keys):
        raise RekeyError("every release scope must use a distinct 32-byte key")
    files: list[dict[str, Any]] = []
    try:
        for scope, relative, source in _target_entries(root):
            target = output / relative
            before = _audit_file(source, relative)
            if any("32" in record["lengths"] for record in before):
                raise RekeyError(
                    f"build input already contains a 32-character identifier; "
                    f"use the preserved legacy source and never HMAC a public candidate again: {relative}"
                )
            _rekey_file(source, target, keys[scope], scope)
            after = _audit_file(target, relative)
            _compare_audits(before, after, relative)
            _compare_non_identifiers(source, target)
            files.append(
                {
                    "scope": scope,
                    "path": relative,
                    "source_sha256": _sha256(source),
                    "candidate_sha256": _sha256(target),
                    "identifiers_before": before,
                    "identifiers_after": after,
                }
            )
        manifest = {
            "format": "urban-wifi-tutorial-public-handoff-v1",
            "algorithm": ALGORITHM,
            "identifier_hex_characters": 32,
            "scope_rule": "separate private key for each named dataset scope",
            "historical_collection_claim": False,
            "created_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "files": files,
        }
        (output / "REKEY_MANIFEST.json").write_text(
            json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
    except Exception:
        shutil.rmtree(output, ignore_errors=True)
        raise
    print(f"built and verified candidate: {output}")
    print(f"files: {len(files)}; keys were not copied or fingerprinted")
    return 0


def verify_candidate(candidate: Path) -> dict[str, Any]:
    candidate = candidate.resolve(strict=True)
    manifest_path = candidate / "REKEY_MANIFEST.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("algorithm") != ALGORITHM or manifest.get("identifier_hex_characters") != 32:
        raise RekeyError("candidate manifest algorithm contract is invalid")
    expected_paths = {relative for relatives in TARGETS.values() for relative in relatives}
    files = manifest.get("files", [])
    if {item.get("path") for item in files} != expected_paths:
        raise RekeyError("candidate manifest target allowlist is incomplete")
    identifiers_by_scope: dict[str, set[str]] = {scope: set() for scope in TARGETS}
    for item in files:
        relative = item["path"]
        path = candidate / relative
        if not path.is_file() or _sha256(path) != item["candidate_sha256"]:
            raise RekeyError(f"candidate checksum mismatch: {relative}")
        after = _audit_file(path, relative)
        if _normalized_audit(after) != _normalized_audit(item["identifiers_after"]):
            raise RekeyError(f"candidate identifier audit mismatch: {relative}")
        if not all(record["all_32_hex"] for record in after):
            raise RekeyError(f"non-32-hex identifier remains: {relative}")
        identifiers_by_scope[item["scope"]].update(_collect_identifiers(path))
    scopes = sorted(identifiers_by_scope)
    for index, left in enumerate(scopes):
        for right in scopes[index + 1 :]:
            if identifiers_by_scope[left] & identifiers_by_scope[right]:
                raise RekeyError(f"identifier overlap across release scopes: {left} / {right}")
    return manifest


def run_verify(args: argparse.Namespace) -> int:
    manifest = verify_candidate(args.candidate)
    print(f"verified candidate: {args.candidate.resolve()}")
    print(f"files: {len(manifest['files'])}; every recognized identifier is 32-hex")
    return 0


def _secret_encodings(key: bytes) -> tuple[bytes, ...]:
    return (
        key,
        key.hex().encode("ascii"),
        base64.b64encode(key),
        base64.urlsafe_b64encode(key),
    )


def _scan_bytes(path: Path, forbidden: tuple[bytes, ...], label: str) -> None:
    payload = path.read_bytes()
    if any(needle and needle in payload for needle in forbidden):
        raise RekeyError(f"release-key material found in candidate object: {label}")
    if path.suffix.lower() == ".zip":
        with zipfile.ZipFile(path, "r") as archive:
            for name in archive.namelist():
                if name.endswith("/"):
                    continue
                member = archive.read(name)
                if any(needle and needle in member for needle in forbidden):
                    raise RekeyError(f"release-key material found in ZIP member: {label}::{name}")


def run_secret_scan(args: argparse.Namespace) -> int:
    candidate = args.candidate.resolve(strict=True)
    manifest = verify_candidate(candidate)
    keys = (
        _read_key(args.ch3_location_key_file),
        _read_key(args.ch3_track_key_file),
        _read_key(args.main_key_file),
        _read_key(args.location_key_file),
    )
    if len(set(keys)) != len(keys):
        raise RekeyError("every release scope must use a distinct 32-byte key")
    forbidden = tuple(item for key in keys for item in _secret_encodings(key))
    for item in manifest["files"]:
        _scan_bytes(candidate / item["path"], forbidden, item["path"])
    _scan_bytes(candidate / "REKEY_MANIFEST.json", forbidden, "REKEY_MANIFEST.json")
    print(f"scanned verified candidate: {candidate}")
    print("no raw, hexadecimal, standard-base64, or URL-safe-base64 key material found")
    return 0


def apply_candidate(args: argparse.Namespace) -> int:
    root = args.repository_root.resolve(strict=True)
    candidate = args.candidate.resolve(strict=True)
    manifest = verify_candidate(candidate)
    for item in manifest["files"]:
        relative = item["path"]
        source = candidate / relative
        target = root / relative
        temporary = target.with_name(target.name + ".rekey-tmp")
        shutil.copy2(source, temporary)
        os.replace(temporary, target)
    print(f"applied verified candidate to {root}")
    print(f"files replaced: {len(manifest['files'])}")
    return 0


def run_audit(args: argparse.Namespace) -> int:
    root = args.repository_root.resolve(strict=True)
    records: list[dict[str, Any]] = []
    for scope, relative, path in _target_entries(root):
        for record in _audit_file(path, relative):
            records.append({"scope": scope, **record})
    print(json.dumps(records, indent=2, ensure_ascii=False))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    audit = subparsers.add_parser("audit", help="report identifier lengths without modification")
    audit.add_argument("--repository-root", type=Path, default=Path.cwd())
    audit.set_defaults(func=run_audit)

    build = subparsers.add_parser("build", help="build an isolated verified candidate")
    build.add_argument("--repository-root", type=Path, default=Path.cwd())
    build.add_argument("--output", required=True, type=Path)
    build.add_argument("--ch3-location-key-file", required=True, type=Path)
    build.add_argument("--ch3-track-key-file", required=True, type=Path)
    build.add_argument("--main-key-file", required=True, type=Path)
    build.add_argument("--location-key-file", required=True, type=Path)
    build.set_defaults(func=build_candidate)

    verify = subparsers.add_parser("verify", help="verify an isolated candidate")
    verify.add_argument("--candidate", required=True, type=Path)
    verify.set_defaults(func=run_verify)

    scan = subparsers.add_parser("scan", help="scan a candidate for release-key material")
    scan.add_argument("--candidate", required=True, type=Path)
    scan.add_argument("--ch3-location-key-file", required=True, type=Path)
    scan.add_argument("--ch3-track-key-file", required=True, type=Path)
    scan.add_argument("--main-key-file", required=True, type=Path)
    scan.add_argument("--location-key-file", required=True, type=Path)
    scan.set_defaults(func=run_secret_scan)

    apply = subparsers.add_parser("apply", help="atomically replace allowlisted public samples")
    apply.add_argument("--repository-root", type=Path, default=Path.cwd())
    apply.add_argument("--candidate", required=True, type=Path)
    apply.set_defaults(func=apply_candidate)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        return args.func(args)
    except (OSError, RekeyError, sqlite3.Error, pa.ArrowException, zipfile.BadZipFile) as exc:
        raise SystemExit(f"error: {exc}") from exc


if __name__ == "__main__":
    raise SystemExit(main())
