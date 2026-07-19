#!/usr/bin/env python3
"""Build and verify the deterministic, allowlisted synthetic tutorial archive."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import tempfile
import zipfile
from pathlib import Path, PurePosixPath
from typing import Mapping


ARCHIVE_NAME = "urban-wifi-synthetic-pipeline.zip"
CHECKSUM_NAME = "urban-wifi-synthetic-pipeline.sha256"
FIXED_ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
REGULAR_FILE_MODE = stat.S_IFREG | 0o644
INTERNAL_README = "README.md"
INTERNAL_MANIFEST = "MANIFEST.sha256"

FIXTURE_PREFIX = "workflow/ch3_tutorial/maintained_capture_fixture"
PIPELINE_OUTPUT_PREFIX = "workflow/ch3_tutorial/maintained_pipeline"
METRIC_OUTPUT_PREFIX = "workflow/ch3_tutorial/maintained_metrics"
FIXTURE_MANIFEST = f"{FIXTURE_PREFIX}/manifest.json"
FIXTURE_DATABASE = f"{FIXTURE_PREFIX}/maintained_capture.sqlite3"
FIXTURE_SENSORS = f"{FIXTURE_PREFIX}/synthetic_sensors.csv"
METRIC_MANIFEST = f"{METRIC_OUTPUT_PREFIX}/manifest.json"

# This is an exact allowlist. Adding a file to one of these directories does
# not add it to the archive; the list and its tests must be changed explicitly.
SOURCE_ALLOWLIST = tuple(
    sorted(
        (
            "scripts/pipeline/_common.R",
            "scripts/pipeline/_metrics_common.R",
            "scripts/pipeline/01_aggregate_sqlite.R",
            "scripts/pipeline/02_clean_1second.R",
            "scripts/pipeline/03_build_20second.R",
            "scripts/pipeline/04_verify_pipeline.R",
            "scripts/pipeline/05_build_five_metrics.R",
            "scripts/pipeline/06_verify_five_metrics.R",
            "scripts/pipeline/README.md",
            "scripts/pipeline/build_synthetic_tutorial_archive.py",
            "scripts/pipeline/run_five_metrics.R",
            "scripts/pipeline/run_pipeline.R",
            "tests/ch3_maintained_fixture/__init__.py",
            "tests/ch3_maintained_fixture/test_fixture.py",
            "tests/synthetic_archive/__init__.py",
            "tests/synthetic_archive/test_synthetic_archive.py",
            f"{FIXTURE_PREFIX}/generate_fixture.py",
            FIXTURE_DATABASE,
            FIXTURE_MANIFEST,
            FIXTURE_SENSORS,
            f"{PIPELINE_OUTPUT_PREFIX}/01_aggregated_1second.parquet",
            f"{PIPELINE_OUTPUT_PREFIX}/02_cleaned_1second.parquet",
            f"{PIPELINE_OUTPUT_PREFIX}/03_analysis_20second.parquet",
            f"{METRIC_OUTPUT_PREFIX}/01_location.csv",
            f"{METRIC_OUTPUT_PREFIX}/02_count.csv",
            f"{METRIC_OUTPUT_PREFIX}/03_track_od.csv",
            f"{METRIC_OUTPUT_PREFIX}/03_track_trajectories.csv",
            f"{METRIC_OUTPUT_PREFIX}/04_revisits.csv",
            f"{METRIC_OUTPUT_PREFIX}/05_activities.csv",
            f"{METRIC_OUTPUT_PREFIX}/README.md",
            METRIC_MANIFEST,
        )
    )
)
ARCHIVE_ALLOWLIST = tuple(
    sorted((INTERNAL_README, INTERNAL_MANIFEST, *SOURCE_ALLOWLIST))
)

README_BYTES = b"""# Urban WiFi synthetic processing tutorial

This self-contained archive exercises the maintained SQLite-to-one-second-to-
20-second processing chain and all five metric calculations. Every observation,
identifier input, sensor coordinate, and timestamp scenario is synthetic. The
archive contains no field record, raw MAC address, deployment or release key,
identifier mapping, geographic coordinate, author identity, or Git history.

The SQLite fixture contains only the minimal `packets` table because no hardware
capture occurred. Its 32-character identifiers are deterministic HMAC outputs
from synthetic scenario-role labels, not observed addresses. The fixture
manifest deliberately prints one fixed public test-only key so the calculation
contract is reproducible. Never use that value for collection or deployment.

## Integrity

The outer `.sha256` file authenticates the downloaded ZIP. Inside the ZIP,
`MANIFEST.sha256` covers every other member. The archive builder verifies the
exact member allowlist, hashes, fixed ZIP metadata, fixture provenance fields,
and privacy scan before extraction.

From a repository checkout, verify and safely extract with:

```text
python scripts/pipeline/build_synthetic_tutorial_archive.py verify --archive docs/downloads/urban-wifi-synthetic-pipeline.zip --checksum docs/downloads/urban-wifi-synthetic-pipeline.sha256 --extract-dir synthetic-tutorial
```

## Offline checks after extraction

Run the eight fixture tests:

```text
python -m unittest discover -s tests/ch3_maintained_fixture -p test_*.py
```

Verify the committed processing outputs and five-metric outputs:

```text
Rscript scripts/pipeline/04_verify_pipeline.R --one-second workflow/ch3_tutorial/maintained_pipeline/01_aggregated_1second.parquet --cleaned-one-second workflow/ch3_tutorial/maintained_pipeline/02_cleaned_1second.parquet --twenty-second workflow/ch3_tutorial/maintained_pipeline/03_analysis_20second.parquet

Rscript scripts/pipeline/06_verify_five_metrics.R --input workflow/ch3_tutorial/maintained_pipeline/03_analysis_20second.parquet --sensors workflow/ch3_tutorial/maintained_capture_fixture/synthetic_sensors.csv --fixture-manifest workflow/ch3_tutorial/maintained_capture_fixture/manifest.json --output-dir workflow/ch3_tutorial/maintained_metrics
```

The Python generator and the two R entry points can rebuild the fixture and
outputs in separate temporary directories. See `scripts/pipeline/README.md` for
the exact commands and declared thresholds. These artifacts test calculation
contracts only. They neither reproduce historical field results nor establish
sensor accuracy, pedestrian counts, anonymity, or permission to release data.
"""

RAW_MAC_RE = re.compile(
    rb"(?i)(?<![0-9a-f])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f])"
)
WINDOWS_HOME_RE = re.compile(
    rb"(?i)[a-z]:[\\/](?:users|documents[ ]and[ ]settings)[\\/][^\x00\r\n\t ]+"
)
POSIX_HOME_RE = re.compile(rb"(?i)/(?:home|users)/[a-z0-9._-]+/")
EMAIL_RE = re.compile(
    rb"(?i)(?<![a-z0-9._%+-])[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}(?![a-z0-9.-])"
)
PUBLIC_TEST_KEY = bytes(range(32)).hex().encode("ascii")
PUBLIC_TEST_KEY_ALLOWED_IN = frozenset((FIXTURE_MANIFEST,))
FORBIDDEN_TEXT = (
    b"urban" + b"juhyeon",
    b"juhyeon" + b"park",
    b"github" + b".com",
    b"netlify" + b".app",
    b"fig" + b"share.com",
    b"zenodo" + b".org",
    b"orcid" + b".org",
    b"begin " + b"private key",
    b"begin openssh " + b"private key",
)
FORBIDDEN_SUFFIXES = (
    ".key",
    ".pem",
    ".p12",
    ".pfx",
    ".pcap",
    ".pcapng",
    ".pyc",
)


class ArchiveValidationError(RuntimeError):
    """Raised when an archive or source violates the frozen contract."""


def repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _validate_member_name(name: str) -> None:
    path = PurePosixPath(name)
    if (
        not name
        or name != path.as_posix()
        or path.is_absolute()
        or ".." in path.parts
        or "" in path.parts
        or "\\" in name
        or name.endswith("/")
    ):
        raise ArchiveValidationError(f"unsafe or noncanonical archive member: {name!r}")
    lowered_parts = tuple(part.lower() for part in path.parts)
    if any(part == ".git" or part.startswith(".git") for part in lowered_parts):
        raise ArchiveValidationError(f"Git metadata is forbidden: {name}")
    if path.suffix.lower() in FORBIDDEN_SUFFIXES:
        raise ArchiveValidationError(f"forbidden file type: {name}")


def _scan_member(name: str, data: bytes) -> None:
    _validate_member_name(name)
    lowered = data.lower()
    if RAW_MAC_RE.search(data):
        raise ArchiveValidationError(f"raw MAC-like value found in {name}")
    if WINDOWS_HOME_RE.search(data) or POSIX_HOME_RE.search(data):
        raise ArchiveValidationError(f"absolute user path found in {name}")
    if EMAIL_RE.search(data):
        raise ArchiveValidationError(f"email address found in {name}")
    for token in FORBIDDEN_TEXT:
        if token in lowered:
            raise ArchiveValidationError(
                f"forbidden identity, host, or private-key marker found in {name}"
            )
    key_occurrences = data.count(PUBLIC_TEST_KEY)
    if key_occurrences and name not in PUBLIC_TEST_KEY_ALLOWED_IN:
        raise ArchiveValidationError(
            f"public synthetic test key occurs outside its manifest: {name}"
        )


def _source_path(root: Path, member: str) -> Path:
    root = root.resolve(strict=True)
    path = root.joinpath(*PurePosixPath(member).parts)
    current = root
    for part in PurePosixPath(member).parts:
        current = current / part
        if current.is_symlink():
            raise ArchiveValidationError(f"symlinked source is forbidden: {member}")
    if not path.is_file():
        raise ArchiveValidationError(f"allowlisted source is missing: {member}")
    resolved = path.resolve(strict=True)
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise ArchiveValidationError(f"source escapes repository root: {member}") from exc
    return resolved


def _load_json(payload: Mapping[str, bytes], name: str) -> dict:
    try:
        value = json.loads(payload[name].decode("utf-8"))
    except (KeyError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ArchiveValidationError(f"invalid JSON member: {name}") from exc
    if not isinstance(value, dict):
        raise ArchiveValidationError(f"JSON member must contain an object: {name}")
    return value


def _validate_synthetic_contract(payload: Mapping[str, bytes]) -> None:
    fixture = _load_json(payload, FIXTURE_MANIFEST)
    privacy = fixture.get("privacy_boundary", {})
    identifier = fixture.get("identifier_contract", {})
    scope = fixture.get("fixture_scope", {})
    if not (
        privacy.get("fully_synthetic") is True
        and privacy.get("raw_mac_addresses_stored") is False
        and privacy.get("original_address_mapping_exists") is False
        and identifier.get("key_is_public") is True
        and identifier.get("key_is_secret") is False
        and identifier.get("key_is_test_only") is True
        and identifier.get("key_must_not_be_used_for_field_collection") is True
        and identifier.get("public_test_key_hex") == PUBLIC_TEST_KEY.decode("ascii")
        and identifier.get("input_kind")
        == "fully synthetic scenario role labels; not MAC addresses"
        and scope.get("minimal_packets_fixture") is True
        and scope.get("no_hardware_capture_occurred") is True
        and scope.get("operational_loss_counters_fabricated") is False
    ):
        raise ArchiveValidationError("fixture privacy and test-key contract changed")
    if fixture.get("database_sha256") != sha256_bytes(payload[FIXTURE_DATABASE]):
        raise ArchiveValidationError("fixture database hash does not match its manifest")
    if fixture.get("sensor_metadata_sha256") != sha256_bytes(payload[FIXTURE_SENSORS]):
        raise ArchiveValidationError("sensor metadata hash does not match its manifest")

    total_key_occurrences = sum(data.count(PUBLIC_TEST_KEY) for data in payload.values())
    if total_key_occurrences != 1:
        raise ArchiveValidationError(
            "the public test-only key must occur exactly once, in the fixture manifest"
        )

    metric = _load_json(payload, METRIC_MANIFEST)
    expected_inputs = {
        "input_20second": f"{PIPELINE_OUTPUT_PREFIX}/03_analysis_20second.parquet",
        "sensor_metadata": FIXTURE_SENSORS,
        "fixture_manifest": FIXTURE_MANIFEST,
    }
    for field, expected in expected_inputs.items():
        if metric.get(field) != expected or expected not in payload:
            raise ArchiveValidationError(f"metric manifest {field} is not self-contained")
    expected_metric_files = {
        "01_location.csv",
        "02_count.csv",
        "03_track_trajectories.csv",
        "03_track_od.csv",
        "04_revisits.csv",
        "05_activities.csv",
    }
    if set(metric.get("output_rows", {})) != expected_metric_files:
        raise ArchiveValidationError("metric output allowlist does not match its manifest")


def _manifest_bytes(payload: Mapping[str, bytes]) -> bytes:
    lines = [f"{sha256_bytes(payload[name])}  {name}\n" for name in sorted(payload)]
    return "".join(lines).encode("utf-8")


def collect_payload(root: Path) -> dict[str, bytes]:
    root = root.resolve(strict=True)
    payload: dict[str, bytes] = {INTERNAL_README: README_BYTES}
    for member in SOURCE_ALLOWLIST:
        payload[member] = _source_path(root, member).read_bytes()
    for name, data in payload.items():
        _scan_member(name, data)
    _validate_synthetic_contract(payload)
    payload[INTERNAL_MANIFEST] = _manifest_bytes(payload)
    _scan_member(INTERNAL_MANIFEST, payload[INTERNAL_MANIFEST])
    if tuple(sorted(payload)) != ARCHIVE_ALLOWLIST:
        raise ArchiveValidationError("payload does not equal the frozen archive allowlist")
    return payload


def _zip_info(name: str) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, FIXED_ZIP_TIMESTAMP)
    info.create_system = 3
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = REGULAR_FILE_MODE << 16
    info.extra = b""
    info.comment = b""
    return info


def _atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="wb", prefix=f".{path.name}.", suffix=".tmp", dir=path.parent, delete=False
    ) as stream:
        temporary = Path(stream.name)
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def build_archive(root: Path, archive: Path, checksum: Path) -> str:
    root = root.resolve(strict=True)
    archive = archive.resolve(strict=False)
    checksum = checksum.resolve(strict=False)
    if archive == checksum:
        raise ArchiveValidationError("archive and checksum paths must differ")
    payload = collect_payload(root)
    archive.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        prefix=f".{archive.name}.", suffix=".tmp", dir=archive.parent, delete=False
    ) as stream:
        temporary = Path(stream.name)
    try:
        with zipfile.ZipFile(
            temporary,
            mode="w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=9,
            strict_timestamps=True,
        ) as output:
            output.comment = b""
            for name in sorted(payload):
                output.writestr(
                    _zip_info(name),
                    payload[name],
                    compress_type=zipfile.ZIP_DEFLATED,
                    compresslevel=9,
                )
        os.replace(temporary, archive)
    finally:
        temporary.unlink(missing_ok=True)

    verify_archive(archive)
    digest = sha256_file(archive)
    _atomic_write(checksum, f"{digest}  {archive.name}\n".encode("ascii"))
    verify_checksum(archive, checksum)
    return digest


def _read_archive_payload(archive: Path) -> dict[str, bytes]:
    if not archive.is_file():
        raise ArchiveValidationError(f"archive is missing: {archive}")
    with zipfile.ZipFile(archive, "r") as source:
        infos = source.infolist()
        names = [info.filename for info in infos]
        if len(names) != len(set(names)):
            raise ArchiveValidationError("archive contains duplicate member names")
        for name in names:
            _validate_member_name(name)
        if names != sorted(ARCHIVE_ALLOWLIST):
            raise ArchiveValidationError("archive member names or order differ from allowlist")
        payload: dict[str, bytes] = {}
        for info in infos:
            mode = (info.external_attr >> 16) & 0xFFFF
            if (
                info.date_time != FIXED_ZIP_TIMESTAMP
                or info.create_system != 3
                or info.compress_type != zipfile.ZIP_DEFLATED
                or mode != REGULAR_FILE_MODE
                or info.extra
                or info.comment
                or info.flag_bits & 0x1
            ):
                raise ArchiveValidationError(
                    f"nondeterministic or unsafe ZIP metadata for {info.filename}"
                )
            payload[info.filename] = source.read(info)
        if source.comment:
            raise ArchiveValidationError("archive comment must be empty")
    return payload


def verify_archive(archive: Path) -> dict[str, bytes]:
    payload = _read_archive_payload(archive)
    expected_manifest = _manifest_bytes(
        {name: data for name, data in payload.items() if name != INTERNAL_MANIFEST}
    )
    if payload[INTERNAL_MANIFEST] != expected_manifest:
        raise ArchiveValidationError("internal SHA-256 manifest does not match members")
    for name, data in payload.items():
        _scan_member(name, data)
    _validate_synthetic_contract(payload)
    return payload


def verify_checksum(archive: Path, checksum: Path) -> str:
    if not checksum.is_file():
        raise ArchiveValidationError(f"checksum file is missing: {checksum}")
    try:
        text = checksum.read_text(encoding="ascii")
    except UnicodeDecodeError as exc:
        raise ArchiveValidationError("checksum file must be ASCII") from exc
    match = re.fullmatch(r"([0-9a-f]{64})  ([^\r\n]+)\n", text)
    if match is None or match.group(2) != archive.name:
        raise ArchiveValidationError("checksum file has an invalid format or filename")
    actual = sha256_file(archive)
    if match.group(1) != actual:
        raise ArchiveValidationError("outer archive SHA-256 does not match")
    return actual


def extract_verified_archive(archive: Path, destination: Path) -> tuple[Path, ...]:
    payload = verify_archive(archive)
    if destination.is_symlink():
        raise ArchiveValidationError("extraction destination must not be a symlink")
    destination.mkdir(parents=True, exist_ok=True)
    if any(destination.iterdir()):
        raise ArchiveValidationError("extraction destination must be empty")
    root = destination.resolve(strict=True)
    written: list[Path] = []
    for name in sorted(payload):
        target = root.joinpath(*PurePosixPath(name).parts)
        try:
            target.resolve(strict=False).relative_to(root)
        except ValueError as exc:
            raise ArchiveValidationError(f"member escapes extraction root: {name}") from exc
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(payload[name])
        target.chmod(0o644)
        written.append(target)
    for name, data in payload.items():
        extracted = root.joinpath(*PurePosixPath(name).parts)
        if sha256_file(extracted) != sha256_bytes(data):
            raise ArchiveValidationError(f"extracted member hash changed: {name}")
    return tuple(written)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    build = subparsers.add_parser("build", help="build and verify the archive")
    build.add_argument("--root", type=Path, default=repository_root())
    build.add_argument("--archive", type=Path)
    build.add_argument("--checksum", type=Path)

    verify = subparsers.add_parser("verify", help="verify an existing archive")
    verify.add_argument("--archive", type=Path, required=True)
    verify.add_argument("--checksum", type=Path)
    verify.add_argument("--extract-dir", type=Path)
    return parser


def main() -> int:
    args = _parser().parse_args()
    if args.command == "build":
        root = args.root.resolve(strict=True)
        archive = args.archive or root / "docs" / "downloads" / ARCHIVE_NAME
        checksum = args.checksum or root / "docs" / "downloads" / CHECKSUM_NAME
        digest = build_archive(root, archive, checksum)
        print(f"built {archive}")
        print(f"sha256 {digest}")
        return 0

    payload = verify_archive(args.archive)
    digest = sha256_file(args.archive)
    if args.checksum is not None:
        digest = verify_checksum(args.archive, args.checksum)
    if args.extract_dir is not None:
        extract_verified_archive(args.archive, args.extract_dir)
        print(f"extracted {len(payload)} verified files to {args.extract_dir}")
    print(f"verified {args.archive}")
    print(f"sha256 {digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
