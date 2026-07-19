"""Idempotent monitor-interface preparation with no shell interpolation."""

from __future__ import annotations

# Only fixed absolute binaries and validated argument vectors are used below.
import json
import subprocess  # nosec B404
import time
from pathlib import Path
from typing import Dict, Iterable, List, Sequence, Set, Tuple

from .config import CaptureConfig, InterfaceConfig


class InterfaceError(RuntimeError):
    """Raised when a monitor interface cannot be prepared or removed."""


IP_BINARY = "/usr/sbin/ip"
IW_BINARY = "/usr/sbin/iw"
NMCLI_BINARY = "/usr/bin/nmcli"


def _exists(name: str) -> bool:
    return (Path("/sys/class/net") / name).exists()


def _run(arguments: Sequence[str]) -> None:
    try:
        # Interface and channel values passed here were allowlist-validated.
        subprocess.run(list(arguments), check=True)  # nosec
    except (OSError, subprocess.CalledProcessError) as exc:
        command = " ".join(arguments)
        raise InterfaceError(f"interface command failed: {command}") from exc


def _run_output(arguments: Sequence[str]) -> str:
    try:
        completed = subprocess.run(  # nosec
            list(arguments),
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        command = " ".join(arguments)
        raise InterfaceError(f"interface discovery command failed: {command}") from exc
    return completed.stdout


def _set_network_manager_managed(name: str, managed: bool) -> None:
    """Release or reclaim an adapter when NetworkManager is present."""

    if not Path(NMCLI_BINARY).exists():
        return
    _run(
        [
            NMCLI_BINARY,
            "device",
            "set",
            name,
            "managed",
            "yes" if managed else "no",
        ]
    )


def _default_route_interfaces() -> Set[str]:
    try:
        routes = json.loads(_run_output([IP_BINARY, "-j", "route", "show", "default"]))
    except json.JSONDecodeError as exc:
        raise InterfaceError("ip returned invalid default-route data") from exc
    if not isinstance(routes, list):
        raise InterfaceError("ip returned invalid default-route data")
    return {
        route["dev"]
        for route in routes
        if isinstance(route, dict) and isinstance(route.get("dev"), str)
    }


def _wireless_interface_types() -> Dict[str, str]:
    result: Dict[str, str] = {}
    current = None
    for raw_line in _run_output([IW_BINARY, "dev"]).splitlines():
        line = raw_line.strip()
        if line.startswith("Interface "):
            current = line.split(None, 1)[1]
        elif current is not None and line.startswith("type "):
            result[current] = line.split(None, 1)[1]
            current = None
    return result


def _resolve_auto_once(channels: Sequence[int]) -> Tuple[InterfaceConfig, ...]:
    wireless = _wireless_interface_types()
    default_routes = _default_route_interfaces()
    management = sorted(
        name for name in default_routes if wireless.get(name) == "managed"
    )
    if len(management) != 1:
        found = ", ".join(management) if management else "none"
        raise InterfaceError(
            "automatic selection requires exactly one managed wireless "
            f"default-route interface; found {found}"
        )

    candidates = sorted(
        name
        for name, interface_type in wireless.items()
        if interface_type == "managed" and name != management[0]
    )
    if len(candidates) != len(channels):
        found = ", ".join(candidates) if candidates else "none"
        raise InterfaceError(
            f"automatic selection expected {len(channels)} capture adapter(s) "
            f"for channels {', '.join(str(value) for value in channels)}, "
            f"but found {len(candidates)}: {found}; management interface "
            f"{management[0]} was excluded"
        )

    return tuple(
        InterfaceConfig(physical=name, monitor=f"ucap{index}", channel=channel)
        for index, (name, channel) in enumerate(zip(candidates, channels))
    )


def resolve_interfaces(
    config: CaptureConfig,
    *,
    wait_seconds: int = 0,
) -> Tuple[InterfaceConfig, ...]:
    """Resolve a static list or safely discover non-management WiFi adapters."""

    if config.interfaces:
        return config.interfaces

    deadline = time.monotonic() + max(0, wait_seconds)
    while True:
        try:
            return _resolve_auto_once(config.auto_channels)
        except InterfaceError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(1)


def capture_interfaces(config: CaptureConfig) -> Tuple[InterfaceConfig, ...]:
    """Return deterministic monitor names without network discovery."""

    if config.interfaces:
        return config.interfaces
    return tuple(
        InterfaceConfig(physical=f"auto{index}", monitor=f"ucap{index}", channel=channel)
        for index, channel in enumerate(config.auto_channels)
    )


def bring_up(item: InterfaceConfig) -> None:
    if not _exists(item.physical):
        raise InterfaceError(f"physical interface does not exist: {item.physical}")
    if _exists(item.monitor):
        raise InterfaceError(
            f"monitor interface already exists and ownership is unknown: {item.monitor}"
        )

    _set_network_manager_managed(item.physical, False)
    time.sleep(1)
    _run([IP_BINARY, "link", "set", item.physical, "down"])
    try:
        _run(
            [
                IW_BINARY,
                "dev",
                item.physical,
                "interface",
                "add",
                item.monitor,
                "type",
                "monitor",
            ]
        )
        _run([IP_BINARY, "link", "set", item.monitor, "up"])
        _run([IW_BINARY, "dev", item.monitor, "set", "channel", str(item.channel)])
    except Exception:
        if _exists(item.monitor):
            # Fixed binary path and allowlist-validated interface; shell=False.
            subprocess.run(  # nosec B603
                [IW_BINARY, "dev", item.monitor, "del"], check=False
            )
        # Fixed binary path and allowlist-validated interface; shell=False.
        subprocess.run(  # nosec B603
            [IP_BINARY, "link", "set", item.physical, "up"], check=False
        )
        try:
            _set_network_manager_managed(item.physical, True)
        except InterfaceError:
            pass
        raise


def bring_down(item: InterfaceConfig) -> None:
    if _exists(item.monitor):
        _run([IW_BINARY, "dev", item.monitor, "del"])
    if _exists(item.physical):
        _run([IP_BINARY, "link", "set", item.physical, "up"])
        _set_network_manager_managed(item.physical, True)


def bring_all_up(items: Iterable[InterfaceConfig]) -> None:
    completed: List[InterfaceConfig] = []
    try:
        for item in items:
            bring_up(item)
            completed.append(item)
    except Exception:
        for item in reversed(completed):
            try:
                bring_down(item)
            except InterfaceError:
                pass
        raise


def bring_all_down(items: Iterable[InterfaceConfig]) -> None:
    failures = []
    for item in reversed(tuple(items)):
        try:
            bring_down(item)
        except InterfaceError as exc:
            failures.append(str(exc))
    if failures:
        raise InterfaceError("; ".join(failures))


def status(items: Iterable[InterfaceConfig]) -> List[str]:
    return [
        f"{item.monitor}: {'present' if _exists(item.monitor) else 'missing'} "
        f"(physical={item.physical}, channel={item.channel})"
        for item in items
    ]
