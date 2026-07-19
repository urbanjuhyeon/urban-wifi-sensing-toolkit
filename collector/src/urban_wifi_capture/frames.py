"""Convert decoded 802.11 frames to privacy-minimized records."""

from __future__ import annotations

import struct
from typing import Any, Dict, Optional

import dpkt

from .identifiers import (
    InvalidSourceAddress,
    Pseudonymizer,
    classify_and_pseudonymize_source,
)
from .model import PacketRecord

MANAGEMENT_TYPE = 0
DATA_TYPE = 2

MANAGEMENT_SUBTYPES: Dict[int, str] = {
    0: "association-request",
    1: "association-response",
    2: "reassociation-request",
    3: "reassociation-response",
    4: "probe-request",
    5: "probe-response",
    8: "beacon",
    9: "announcement-traffic-indication-message",
    10: "disassociation",
    11: "authentication",
    12: "deauthentication",
    13: "action",
}

DATA_SUBTYPES: Dict[int, str] = {
    0: "data",
    1: "data-and-contention-free-acknowledgement",
    2: "data-and-contention-free-poll",
    3: "data-and-contention-free-acknowledgement-plus-poll",
    4: "null",
    5: "contention-free-acknowledgement",
    6: "contention-free-poll",
    7: "contention-free-acknowledgement-plus-poll",
    8: "qos-data",
    9: "qos-data-plus-contention-free-acknowledgement",
    10: "qos-data-plus-contention-free-poll",
    11: "qos-data-plus-contention-free-acknowledgement-plus-poll",
    12: "qos-null",
    14: "qos-contention-free-poll-empty",
}


def _signal_strength(packet: Any) -> Optional[int]:
    antenna = getattr(packet, "ant_sig", None)
    value = getattr(antenna, "db", None)
    try:
        strength = int(value)
    except (TypeError, ValueError):
        return None
    if not -127 <= strength <= 0:
        return None
    return strength


def record_from_decoded(
    packet: Any,
    *,
    timestamp: str,
    channel: int,
    sensor_name: str,
    pseudonymizer: Pseudonymizer,
) -> Optional[PacketRecord]:
    """Return a safe record or ``None`` for a frame outside the contract.

    The returned object contains neither the frame bytes nor any raw address.
    Callers must discard their packet object immediately after this function.
    """

    strength = _signal_strength(packet)
    if strength is None:
        return None

    frame = getattr(packet, "data", None)
    frame_type = getattr(frame, "type", None)
    subtype_number = getattr(frame, "subtype", None)

    if frame_type == MANAGEMENT_TYPE:
        if subtype_number == 8:  # beacons originate from fixed infrastructure
            return None
        body = getattr(frame, "mgmt", None)
        raw_source = getattr(body, "src", None)
        record_type = "management"
        subtype = MANAGEMENT_SUBTYPES.get(subtype_number, f"unknown-{subtype_number}")
    elif frame_type == DATA_TYPE:
        # Radiotap RSSI belongs to the over-the-air transmitter (address 2).
        # In FromDS frames dpkt's ``src`` is address 3 (the logical source on
        # the distribution system), so pairing it with that RSSI is invalid.
        # Keep only direct/IBSS and client-originated ToDS frames, for which
        # dpkt's ``data_frame.src`` is the transmitter address; exclude FromDS
        # and four-address WDS traffic.
        to_ds = getattr(frame, "to_ds", 0)
        from_ds = getattr(frame, "from_ds", 0)
        if from_ds or to_ds not in (0, 1):
            return None
        body = getattr(frame, "data_frame", None)
        raw_source = getattr(body, "src", None)
        record_type = "data"
        subtype = DATA_SUBTYPES.get(subtype_number, f"unknown-{subtype_number}")
    else:
        return None

    try:
        token = classify_and_pseudonymize_source(raw_source, pseudonymizer)
    except (InvalidSourceAddress, TypeError):
        return None
    if token is None:
        return None

    return PacketRecord(
        timestamp=timestamp,
        type=record_type,
        subtype=subtype,
        strength=strength,
        source_address=token.identifier,
        source_address_randomized=token.randomized,
        channel=channel,
        sensor_name=sensor_name,
    )


def parse_frame(
    frame_bytes: bytes,
    *,
    timestamp: str,
    channel: int,
    sensor_name: str,
    pseudonymizer: Pseudonymizer,
) -> Optional[PacketRecord]:
    """Decode one radiotap frame without exposing packet content in errors."""

    try:
        packet = dpkt.radiotap.Radiotap(frame_bytes)
    except (dpkt.UnpackError, struct.error, ValueError, IndexError):
        # Packet bytes and raw addresses are intentionally excluded from logs.
        return None
    return record_from_decoded(
        packet,
        timestamp=timestamp,
        channel=channel,
        sensor_name=sensor_name,
        pseudonymizer=pseudonymizer,
    )
