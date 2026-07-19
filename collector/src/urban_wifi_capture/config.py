"""Strict JSON configuration loading."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterable, Mapping, Optional, Tuple

from .identifiers import (
    DEPLOYMENT_ID_RE,
    IDENTIFIER_SCHEME,
    IDENTIFIER_SCOPE,
    Pseudonymizer,
)
from .keys import load_pseudonymization_key

SENSOR_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$")
INTERFACE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,14}$")
ROOT_KEYS = {
    "sensor_name",
    "deployment_id",
    "pseudonymization_key_file",
    "data_dir",
    "queue_size",
    "batch_size",
    "interfaces",
}
INTERFACE_KEYS = {"physical", "monitor", "channel"}
AUTO_INTERFACE_KEYS = {"mode", "channels"}
PLACEHOLDER_SENSOR_NAMES = {"CHANGE_ME", "REPLACE_ME"}
PLACEHOLDER_DEPLOYMENT_IDS = {"CHANGE_ME", "REPLACE_ME", "CHANGE_ME_DEPLOYMENT"}


class ConfigurationError(ValueError):
    """Raised for unsafe, incomplete, or ambiguous configuration."""


@dataclass(frozen=True)
class InterfaceConfig:
    physical: str
    monitor: str
    channel: int

    def __post_init__(self) -> None:
        if type(self.physical) is not str or type(self.monitor) is not str:
            raise ConfigurationError("interface names must be strings")
        if type(self.channel) is not int:
            raise ConfigurationError("channel must be an integer")
        if not INTERFACE_RE.fullmatch(self.physical):
            raise ConfigurationError(f"invalid physical interface: {self.physical!r}")
        if not INTERFACE_RE.fullmatch(self.monitor):
            raise ConfigurationError(f"invalid monitor interface: {self.monitor!r}")
        if self.physical == self.monitor:
            raise ConfigurationError("physical and monitor interface names must differ")
        if not 1 <= self.channel <= 14:
            raise ConfigurationError("only 2.4 GHz channels 1-14 are supported")


@dataclass(frozen=True)
class CaptureConfig:
    sensor_name: str
    deployment_id: str
    pseudonymization_key_file: Path
    data_dir: Path
    interfaces: Tuple[InterfaceConfig, ...]
    auto_channels: Tuple[int, ...]
    queue_size: int = 50000
    batch_size: int = 1000
    pseudonymization_key: Optional[bytes] = field(default=None, repr=False)

    def __post_init__(self) -> None:
        if type(self.sensor_name) is not str:
            raise ConfigurationError("sensor_name must be a string")
        if type(self.deployment_id) is not str:
            raise ConfigurationError("deployment_id must be a string")
        if type(self.queue_size) is not int:
            raise ConfigurationError("queue_size must be an integer")
        if type(self.batch_size) is not int:
            raise ConfigurationError("batch_size must be an integer")
        if not SENSOR_RE.fullmatch(self.sensor_name):
            raise ConfigurationError(
                "sensor_name must be 1-32 characters using letters, digits, _ or -"
            )
        if self.sensor_name in PLACEHOLDER_SENSOR_NAMES:
            raise ConfigurationError("replace the placeholder with an opaque sensor code")
        if not DEPLOYMENT_ID_RE.fullmatch(self.deployment_id):
            raise ConfigurationError(
                "deployment_id must be 1-64 characters using letters, digits, _ or -"
            )
        if self.deployment_id in PLACEHOLDER_DEPLOYMENT_IDS:
            raise ConfigurationError("replace the placeholder with an opaque deployment code")
        if not self.pseudonymization_key_file.is_absolute():
            raise ConfigurationError("pseudonymization_key_file must resolve to an absolute path")
        if self.pseudonymization_key is not None and (
            type(self.pseudonymization_key) is not bytes or len(self.pseudonymization_key) != 32
        ):
            raise ConfigurationError("pseudonymization key must contain exactly 32 bytes")
        if bool(self.interfaces) == bool(self.auto_channels):
            raise ConfigurationError(
                "configure either a static interface list or automatic channel selection"
            )
        if self.auto_channels:
            for channel in self.auto_channels:
                if type(channel) is not int or not 1 <= channel <= 14:
                    raise ConfigurationError(
                        "automatic capture channels must be integers from 1 to 14"
                    )
            if len(set(self.auto_channels)) != len(self.auto_channels):
                raise ConfigurationError("automatic capture channels must be unique")
        if not 100 <= self.queue_size <= 250_000:
            raise ConfigurationError("queue_size must be between 100 and 250000")
        if not 1 <= self.batch_size <= 10000:
            raise ConfigurationError("batch_size must be between 1 and 10000")

        physical = [item.physical for item in self.interfaces]
        monitor = [item.monitor for item in self.interfaces]
        if len(physical) != len(set(physical)):
            raise ConfigurationError("physical interface names must be unique")
        if len(monitor) != len(set(monitor)):
            raise ConfigurationError("monitor interface names must be unique")
        overlap = sorted(set(physical) & set(monitor))
        if overlap:
            raise ConfigurationError(
                "physical and monitor interface sets must not overlap: " + ", ".join(overlap)
            )

    def pseudonymizer(self) -> Pseudonymizer:
        if self.pseudonymization_key is None:
            raise ConfigurationError("pseudonymization key was not loaded")
        return Pseudonymizer(self.deployment_id, self.pseudonymization_key)


def _reject_unknown(mapping: Mapping[str, Any], allowed: Iterable[str], scope: str) -> None:
    unknown = sorted(set(mapping) - set(allowed))
    if unknown:
        raise ConfigurationError(f"unknown {scope} key(s): {', '.join(unknown)}")


def _required(mapping: Mapping[str, Any], key: str, scope: str) -> Any:
    if key not in mapping:
        raise ConfigurationError(f"missing {scope} key: {key}")
    return mapping[key]


def _object_without_duplicates(pairs: Iterable[Tuple[str, Any]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ConfigurationError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _required_string(mapping: Mapping[str, Any], key: str, scope: str) -> str:
    value = _required(mapping, key, scope)
    if type(value) is not str:
        raise ConfigurationError(f"{scope} key {key} must be a string")
    return value


def _integer(mapping: Mapping[str, Any], key: str, default: int, scope: str) -> int:
    value = mapping.get(key, default)
    if type(value) is not int:
        raise ConfigurationError(f"{scope} key {key} must be an integer")
    return value


def load_config(path: Path, *, read_key: bool = True) -> CaptureConfig:
    path = Path(path).expanduser().resolve()
    try:
        content = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_object_without_duplicates,
        )
    except OSError as exc:
        raise ConfigurationError(f"cannot read configuration: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ConfigurationError(f"invalid JSON configuration: {exc}") from exc

    if not isinstance(content, dict):
        raise ConfigurationError("configuration root must be a JSON object")
    _reject_unknown(content, ROOT_KEYS, "configuration")

    raw_interfaces = _required(content, "interfaces", "configuration")
    interfaces = []
    auto_channels = []
    if isinstance(raw_interfaces, list):
        for index, raw in enumerate(raw_interfaces):
            if not isinstance(raw, dict):
                raise ConfigurationError(f"interfaces[{index}] must be an object")
            _reject_unknown(raw, INTERFACE_KEYS, f"interfaces[{index}]")
            interfaces.append(
                InterfaceConfig(
                    physical=_required_string(raw, "physical", f"interfaces[{index}]"),
                    monitor=_required_string(raw, "monitor", f"interfaces[{index}]"),
                    channel=_integer(raw, "channel", 0, f"interfaces[{index}]"),
                )
            )
    elif isinstance(raw_interfaces, dict):
        _reject_unknown(raw_interfaces, AUTO_INTERFACE_KEYS, "automatic interfaces")
        if _required_string(raw_interfaces, "mode", "automatic interfaces") != "auto":
            raise ConfigurationError("automatic interfaces mode must be 'auto'")
        raw_channels = _required(raw_interfaces, "channels", "automatic interfaces")
        if not isinstance(raw_channels, list) or not raw_channels:
            raise ConfigurationError("automatic interfaces channels must be a non-empty array")
        auto_channels = list(raw_channels)
    else:
        raise ConfigurationError("interfaces must be an array or an automatic-selection object")

    data_dir = Path(_required_string(content, "data_dir", "configuration")).expanduser()
    if not data_dir.is_absolute():
        data_dir = (path.parent / data_dir).absolute()
    else:
        data_dir = data_dir.absolute()

    key_file = Path(
        _required_string(content, "pseudonymization_key_file", "configuration")
    ).expanduser()
    if not key_file.is_absolute():
        key_file = (path.parent / key_file).absolute()
    else:
        key_file = key_file.absolute()
    key = load_pseudonymization_key(key_file) if read_key else None

    return CaptureConfig(
        sensor_name=_required_string(content, "sensor_name", "configuration"),
        deployment_id=_required_string(content, "deployment_id", "configuration"),
        pseudonymization_key_file=key_file,
        data_dir=data_dir,
        interfaces=tuple(interfaces),
        auto_channels=tuple(auto_channels),
        queue_size=_integer(content, "queue_size", 50000, "configuration"),
        batch_size=_integer(content, "batch_size", 1000, "configuration"),
        pseudonymization_key=key,
    )


def public_summary(config: CaptureConfig) -> Dict[str, Any]:
    """Return a safe summary with no secret-bearing configuration fields."""

    return {
        "sensor_name": config.sensor_name,
        "deployment_id": config.deployment_id,
        "identifier_scheme": IDENTIFIER_SCHEME,
        "identifier_scope": IDENTIFIER_SCOPE,
        "pseudonymization_key_validated": config.pseudonymization_key is not None,
        "data_dir": str(config.data_dir),
        "queue_size": config.queue_size,
        "batch_size": config.batch_size,
        "interfaces": (
            {
                "mode": "auto",
                "channels": list(config.auto_channels),
                "excludes": "managed wireless default-route interface",
            }
            if config.auto_channels
            else [
                {
                    "physical": item.physical,
                    "monitor": item.monitor,
                    "channel": item.channel,
                }
                for item in config.interfaces
            ]
        ),
        "timestamp_timezone": "UTC",
        "raw_frames_stored": False,
        "raw_addresses_stored": False,
        "ssid_stored": False,
        "bssid_stored": False,
        "destination_address_stored": False,
        "bluetooth_stored": False,
        "cloud_upload_enabled": False,
    }
