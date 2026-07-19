"""Remove the derivable strength_sum column from the shipped public data package.

On every row of both 20-second files, strength_sum equals
100 * detections + rssi_sum (the sum(100 + RSSI) aggregation identity).
The public sample archives in the online documentation already ship without
the column and every consumer restores it at load time, so the shipped
package follows the same contract.

The script refuses to modify anything unless the identity holds exactly on
every row. It then rewrites each Parquet file without the column, verifies
that the six remaining columns are value-identical to the original, replaces
the file, regenerates MANIFEST.sha256, and records the evidence in
SLIM_TRANSFORM.md.

The stage-3 and stage-4 verifiers documented in README.md continue to
validate the seven-column pipeline candidate; this transform applies only to
the shipped copy of the package.

Usage:
    python scripts/release/slim_public_data_package.py --package data/release-20sec
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
from pathlib import Path

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq

PARQUET_FILES = ("wifi_unist19_20sec.parquet", "wifi_uou20_20sec.parquet")
DROPPED_COLUMN = "strength_sum"
BATCH_ROWS = 1_000_000


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_identity(pf: pq.ParquetFile) -> tuple[int, float]:
    """Return (row_count, max abs deviation of the strength_sum identity)."""
    rows = 0
    max_dev = 0.0
    columns = ["rssi_sum", "detections", DROPPED_COLUMN]
    for batch in pf.iter_batches(batch_size=BATCH_ROWS, columns=columns):
        derived = pc.add(
            pc.multiply(pc.cast(batch["detections"], "double"), 100.0),
            batch["rssi_sum"],
        )
        deviation = pc.max(pc.abs_checked(pc.subtract(batch[DROPPED_COLUMN], derived)))
        max_dev = max(max_dev, deviation.as_py())
        rows += batch.num_rows
    return rows, max_dev


def write_slim(pf: pq.ParquetFile, keep: list[str], schema: pa.Schema, tmp: Path) -> None:
    with pq.ParquetWriter(tmp, schema, compression="zstd") as writer:
        for batch in pf.iter_batches(batch_size=BATCH_ROWS, columns=keep):
            writer.write_table(pa.Table.from_batches([batch], schema=schema))


def verify_columns_identical(original: Path, slim: Path, keep: list[str]) -> None:
    for column in keep:
        left = pq.read_table(original, columns=[column])[column].combine_chunks()
        right = pq.read_table(slim, columns=[column])[column].combine_chunks()
        if len(left) != len(right):
            raise SystemExit(f"row count mismatch on {column}")
        equal = pc.equal(left, right)
        if equal.null_count != 0 or not pc.all(equal).as_py():
            raise SystemExit(f"value mismatch on {column}")


def regenerate_manifest(package: Path) -> None:
    manifest = package / "MANIFEST.sha256"
    names = sorted(
        entry.name
        for entry in package.iterdir()
        if entry.is_file() and entry.name != manifest.name
    )
    lines = [f"{sha256_of(package / name)} *{name}" for name in names]
    with manifest.open("w", encoding="ascii", newline="\n") as handle:
        handle.write("\n".join(lines) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", default="data/release-20sec")
    parser.add_argument("--date", default="2026-07-17")
    args = parser.parse_args()
    package = Path(args.package)

    records = []
    for name in PARQUET_FILES:
        path = package / name
        if not path.exists():
            raise SystemExit(f"missing {path}")
        pf = pq.ParquetFile(path)
        schema = pf.schema_arrow
        if DROPPED_COLUMN not in schema.names:
            raise SystemExit(f"{name} has no {DROPPED_COLUMN} column; already slim?")
        keep = [field for field in schema.names if field != DROPPED_COLUMN]
        slim_schema = pa.schema([schema.field(field) for field in keep])

        rows, max_dev = verify_identity(pf)
        if max_dev != 0.0:
            raise SystemExit(
                f"{name}: identity violated (max deviation {max_dev}); aborting"
            )

        tmp = path.with_suffix(".slim.tmp")
        write_slim(pf, keep, slim_schema, tmp)
        verify_columns_identical(path, tmp, keep)
        pf.close()

        before_hash, before_size = sha256_of(path), path.stat().st_size
        after_hash, after_size = sha256_of(tmp), tmp.stat().st_size
        os.replace(tmp, path)
        records.append(
            {
                "name": name,
                "rows": rows,
                "before_hash": before_hash,
                "after_hash": after_hash,
                "before_size": before_size,
                "after_size": after_size,
            }
        )
        print(
            f"{name}: {rows:,} rows, identity exact, "
            f"{before_size / 1e6:.1f} -> {after_size / 1e6:.1f} MB"
        )

    log = package / "SLIM_TRANSFORM.md"
    lines = [
        "# Slim transform record",
        "",
        f"Date: {args.date}",
        "",
        f"The `{DROPPED_COLUMN}` column was removed from both Parquet files because",
        "it equals `100 * detections + rssi_sum` on every row. The identity was",
        "verified exactly (zero deviation) on every row before removal, and the six",
        "remaining columns were verified value-identical after the rewrite. Restore",
        f"the column with `{DROPPED_COLUMN} = 100 * detections + rssi_sum`.",
        "",
        "| File | Rows | Identity max deviation | SHA-256 before | SHA-256 after |",
        "|---|---|---|---|---|",
    ]
    for record in records:
        lines.append(
            f"| `{record['name']}` | {record['rows']:,} | 0.0 "
            f"| `{record['before_hash']}` | `{record['after_hash']}` |"
        )
    lines += [
        "",
        "Produced by `scripts/release/slim_public_data_package.py`, which refuses",
        "to write unless the identity holds exactly. `MANIFEST.sha256` was",
        "regenerated after the transform.",
    ]
    with log.open("w", encoding="ascii", newline="\n") as handle:
        handle.write("\n".join(lines) + "\n")
    regenerate_manifest(package)
    print(f"wrote {log.name} and regenerated MANIFEST.sha256")


if __name__ == "__main__":
    main()
