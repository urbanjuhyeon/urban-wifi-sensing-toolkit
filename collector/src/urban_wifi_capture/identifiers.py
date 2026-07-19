"""Canonical source-address classification and pseudonymization.

Raw source-address bytes must not leave this module's caller. Classification
is performed before HMAC because the locally administered bit is destroyed by
pseudonymization.
"""

from __future__ import annotations

import hashlib
import hmac
import re
from dataclasses import dataclass, field
from typing import Optional, Sequence, Tuple, Union

IDENTIFIER_ALGORITHM = "hmac-sha256"
IDENTIFIER_SCHEME = "hmac-sha256-128-v1"
IDENTIFIER_SCOPE = "deployment"
IDENTIFIER_HEX_LENGTH = 32
PUBLIC_IDENTIFIER_RE = re.compile(r"^[0-9a-f]{32}$")
CANONICAL_MAC_RE = re.compile(r"^[0-9a-f]{2}(?::[0-9a-f]{2}){5}$")
DEPLOYMENT_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
DOMAIN_SEPARATOR = (
    b"urban-wifi-capture\x00hmac-sha256-128-v1\x00deployment\x00"  # pragma: allowlist secret
)


class InvalidSourceAddress(ValueError):
    """Raised when an address cannot be represented as six octets."""


@dataclass(frozen=True)
class AddressToken:
    """The only source-address representation allowed beyond packet parsing."""

    identifier: str
    randomized: int

    def __post_init__(self) -> None:
        if not PUBLIC_IDENTIFIER_RE.fullmatch(self.identifier):
            raise ValueError("identifier must contain exactly 32 lowercase hex characters")
        if self.randomized not in (0, 1):
            raise ValueError("randomized must be 0 or 1")


AddressInput = Union[str, bytes, bytearray, memoryview, Sequence[int]]


@dataclass(frozen=True)
class Pseudonymizer:
    """Deployment-scoped HMAC context safe to pass to capture workers."""

    deployment_id: str
    key: bytes = field(repr=False)

    def __post_init__(self) -> None:
        if type(self.deployment_id) is not str or not DEPLOYMENT_ID_RE.fullmatch(
            self.deployment_id
        ):
            raise ValueError("deployment_id must be a validated opaque ASCII code")
        if type(self.key) is not bytes or len(self.key) != 32:
            raise ValueError("pseudonymization key must contain exactly 32 bytes")

    def pseudonymize(self, canonical_mac: str) -> str:
        if type(canonical_mac) is not str or not CANONICAL_MAC_RE.fullmatch(canonical_mac):
            raise ValueError("canonical_mac must be lowercase colon-separated hexadecimal")
        deployment = self.deployment_id.encode("ascii")
        canonical = canonical_mac.encode("ascii")
        message = (
            DOMAIN_SEPARATOR + len(deployment).to_bytes(2, "big") + deployment + b"\x00" + canonical
        )
        return hmac.new(self.key, message, hashlib.sha256).digest()[:16].hex()


def _coerce_octets(address: AddressInput) -> Tuple[int, int, int, int, int, int]:
    if isinstance(address, str):
        text = address.strip().lower().replace("-", ":")
        parts = text.split(":")
        if len(parts) != 6 or any(len(part) != 2 for part in parts):
            raise InvalidSourceAddress("source address must contain six two-digit octets")
        try:
            values = tuple(int(part, 16) for part in parts)
        except ValueError as exc:
            raise InvalidSourceAddress("source address contains a non-hexadecimal octet") from exc
    elif isinstance(address, (bytes, bytearray, memoryview)):
        values = tuple(bytes(address))
    else:
        try:
            values = tuple(int(value) for value in address)
        except (TypeError, ValueError) as exc:
            raise InvalidSourceAddress("source address must be bytes or six octets") from exc

    if len(values) != 6 or any(value < 0 or value > 255 for value in values):
        raise InvalidSourceAddress("source address must contain exactly six octets")
    return values  # type: ignore[return-value]


def _format_octets(octets: Sequence[int]) -> str:
    return ":".join(f"{value:02x}" for value in octets)


def classify_and_pseudonymize_source(
    address: AddressInput,
    pseudonymizer: Pseudonymizer,
) -> Optional[AddressToken]:
    """Classify and pseudonymize one valid unicast source address.

    All-zero, broadcast, and other group/multicast source addresses return
    ``None`` and must not be persisted. The locally administered bit is read
    from the first raw octet before the canonical string is pseudonymized.
    """

    octets = _coerce_octets(address)
    if all(value == 0 for value in octets):
        return None
    if all(value == 255 for value in octets):
        return None
    if octets[0] & 0x01:  # I/G bit: group or multicast address
        return None

    randomized = int(bool(octets[0] & 0x02))  # U/L bit, before HMAC
    canonical = _format_octets(octets)
    return AddressToken(pseudonymizer.pseudonymize(canonical), randomized)


def is_public_identifier(value: object) -> bool:
    return bool(PUBLIC_IDENTIFIER_RE.fullmatch(str(value)))
