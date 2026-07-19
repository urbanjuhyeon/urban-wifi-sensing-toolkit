"""Command-line interface for validation, interface setup, and capture."""

from __future__ import annotations

import argparse
import json
import logging
import sqlite3
import tempfile
from dataclasses import replace
from pathlib import Path
from typing import Optional, Sequence

from .collector import run_capture, validate_runtime_data_dir
from .config import ConfigurationError, load_config, public_summary
from .database import PACKET_COLUMNS, connect_database, insert_records, metadata_for_deployment
from .identifiers import Pseudonymizer, classify_and_pseudonymize_source
from .interfaces import (
    InterfaceError,
    bring_all_down,
    bring_all_up,
    capture_interfaces,
    resolve_interfaces,
    status,
)
from .keys import generate_pseudonymization_key, load_pseudonymization_key
from .model import PacketRecord


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="urban-wifi-capture",
        description="Privacy-minimized WiFi capture reference implementation",
    )
    parser.add_argument(
        "--log-level", choices=("DEBUG", "INFO", "WARNING", "ERROR"), default="INFO"
    )
    commands = parser.add_subparsers(dest="command", required=True)

    validate = commands.add_parser("validate", help="validate a JSON configuration without capture")
    validate.add_argument("--config", type=Path, required=True)

    capture = commands.add_parser("capture", help="capture from preconfigured monitor interfaces")
    capture.add_argument("--config", type=Path, required=True)

    interfaces = commands.add_parser("interfaces", help="prepare or remove monitor interfaces")
    interfaces.add_argument("action", choices=("plan", "up", "down", "status"))
    interfaces.add_argument("--config", type=Path, required=True)

    generate = commands.add_parser(
        "generate-key",
        help="create one new 32-byte deployment key without overwriting",
    )
    generate.add_argument("--output", type=Path, required=True)

    commands.add_parser("self-test", help="run a hardware-independent SQLite privacy check")
    return parser


def _self_test() -> None:
    deployment_id = "DEPLOYMENT_TEST_2026"
    fixed = Pseudonymizer(deployment_id, bytes(range(32)))
    token = classify_and_pseudonymize_source("AA:BB:CC:DD:EE:FF", fixed)
    if token is None:
        raise RuntimeError("identifier self-test unexpectedly rejected the test vector")
    if token.identifier != "e6ef51ca345d85b9eebaf92e2dc5d20e":  # pragma: allowlist secret
        raise RuntimeError("identifier self-test did not match the fixed HMAC vector")
    with tempfile.TemporaryDirectory(prefix="urban-wifi-capture-") as directory:
        key_path = Path(directory) / "self-test.key"
        generate_pseudonymization_key(key_path)
        generated = Pseudonymizer(deployment_id, load_pseudonymization_key(key_path))
        generated_token = classify_and_pseudonymize_source("AA:BB:CC:DD:EE:FF", generated)
        if generated_token is None or len(generated_token.identifier) != 32:
            raise RuntimeError("generated-key self-test failed")
        path = Path(directory) / "self-test.sqlite3"
        connection = connect_database(path, deployment_id)
        insert_records(
            connection,
            [
                PacketRecord(
                    timestamp="2026-01-01T00:00:00.000000Z",
                    type="management",
                    subtype="probe-request",
                    strength=-55,
                    source_address=token.identifier,
                    source_address_randomized=token.randomized,
                    channel=1,
                    sensor_name="TEST01",
                )
            ],
        )
        columns = tuple(row[1] for row in connection.execute("PRAGMA table_info(packets)"))
        metadata = dict(connection.execute("SELECT key, value FROM capture_metadata"))
        count = connection.execute("SELECT count(*) FROM packets").fetchone()[0]
        connection.close()
        if (
            columns != PACKET_COLUMNS
            or count != 1
            or metadata != metadata_for_deployment(deployment_id)
        ):
            raise RuntimeError("SQLite self-test did not satisfy the public contract")


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)s %(processName)s %(message)s",
    )

    try:
        if args.command == "self-test":
            _self_test()
            print("self-test: PASS")
            return 0
        if args.command == "generate-key":
            path = generate_pseudonymization_key(args.output)
            print(f"created private pseudonymization key file: {path}")
            return 0

        read_key = not (
            args.command == "interfaces" and args.action in ("plan", "down", "status")
        )
        config = load_config(args.config, read_key=read_key)
        if args.command == "validate":
            validate_runtime_data_dir(config.data_dir)
            print(json.dumps(public_summary(config), indent=2, sort_keys=True))
            print("configuration: VALID")
            return 0
        if args.command == "interfaces":
            resolved = resolve_interfaces(
                config,
                wait_seconds=60 if args.action == "up" else 0,
            )
            if args.action == "up":
                for item in resolved:
                    print(
                        f"selected {item.physical} -> {item.monitor} "
                        f"on channel {item.channel}"
                    )
                bring_all_up(resolved)
            elif args.action == "down":
                bring_all_down(resolved)
            elif args.action == "status":
                for line in status(resolved):
                    print(line)
            else:
                for item in resolved:
                    print(
                        f"{item.monitor}: planned "
                        f"(physical={item.physical}, channel={item.channel})"
                    )
            return 0
        if args.command == "capture":
            runtime_config = replace(
                config,
                interfaces=capture_interfaces(config),
                auto_channels=(),
            )
            path = run_capture(runtime_config)
            print(path)
            return 0
    except (ConfigurationError, InterfaceError, RuntimeError, sqlite3.Error, OSError) as exc:
        parser.exit(1, f"error: {exc}\n")

    parser.error("unknown command")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
