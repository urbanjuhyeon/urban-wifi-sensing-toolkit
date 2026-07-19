"""Data objects that are safe to cross the packet-capture boundary."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Tuple

from .identifiers import is_public_identifier


@dataclass(frozen=True)
class PacketRecord:
    timestamp: str
    type: str
    subtype: str
    strength: int
    source_address: str
    source_address_randomized: int
    channel: int
    sensor_name: str

    def __post_init__(self) -> None:
        if not self.timestamp.endswith("Z") or "T" not in self.timestamp:
            raise ValueError("timestamp must be UTC RFC 3339 text ending in Z")
        if self.type not in ("management", "data"):
            raise ValueError("type must be management or data")
        if not self.subtype:
            raise ValueError("subtype must not be empty")
        if not -127 <= int(self.strength) <= 0:
            raise ValueError("strength must be between -127 and 0 dBm")
        if not is_public_identifier(self.source_address):
            raise ValueError("source_address must be a canonical 32-character deployment token")
        if self.source_address_randomized not in (0, 1):
            raise ValueError("source_address_randomized must be 0 or 1")
        if not 1 <= int(self.channel) <= 14:
            raise ValueError("channel must be between 1 and 14")
        if not self.sensor_name:
            raise ValueError("sensor_name must not be empty")

    def as_tuple(self) -> Tuple[object, ...]:
        return (
            self.timestamp,
            self.type,
            self.subtype,
            int(self.strength),
            self.source_address,
            int(self.source_address_randomized),
            int(self.channel),
            self.sensor_name,
        )


@dataclass(frozen=True)
class CaptureSummary:
    """Non-packet run diagnostics used to audit observation loss."""

    interface: str
    channel: int
    pcap_received: int
    pcap_dropped: int
    interface_dropped: int
    queue_dropped: int
    records_emitted: int
    records_filtered: int
    completed_at: str

    def __post_init__(self) -> None:
        if not self.interface or len(self.interface) > 15:
            raise ValueError("interface must be a validated Linux interface name")
        if not 1 <= self.channel <= 14:
            raise ValueError("channel must be between 1 and 14")
        for value in (
            self.pcap_received,
            self.pcap_dropped,
            self.interface_dropped,
        ):
            if type(value) is not int or value < -1:
                raise ValueError("pcap counters must be non-negative or -1 when unavailable")
        for value in (
            self.queue_dropped,
            self.records_emitted,
            self.records_filtered,
        ):
            if type(value) is not int or value < 0:
                raise ValueError("collector counters must be non-negative")
        if not self.completed_at.endswith("Z") or "T" not in self.completed_at:
            raise ValueError("completed_at must be UTC RFC 3339 text ending in Z")

    def as_tuple(self) -> Tuple[object, ...]:
        return (
            self.interface,
            self.channel,
            self.pcap_received,
            self.pcap_dropped,
            self.interface_dropped,
            self.queue_dropped,
            self.records_emitted,
            self.records_filtered,
            self.completed_at,
        )
