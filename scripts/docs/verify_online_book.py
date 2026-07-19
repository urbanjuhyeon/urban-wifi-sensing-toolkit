#!/usr/bin/env python3
"""Fail-closed verification for rendered public or anonymous online books.

The verifier checks rendered links and resources rather than trusting a
successful Quarto exit status.  The synthetic tutorial's fixed public test key
is the sole key-material exception: its own archive verifier requires the
value to occur exactly once, in the fully synthetic fixture manifest.  The
exception never applies to rendered pages, the capture archive, or any other
synthetic-archive member.  The capture source archive has a separate, frozen
file-and-count allowlist for non-observed MAC test vectors needed by its unit
tests; address-like values remain forbidden everywhere else.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import re
import stat
import zipfile
from collections import Counter
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path, PurePosixPath
from types import ModuleType
from typing import Mapping
from urllib.parse import unquote, urlsplit


CAPTURE_ARCHIVE = Path("downloads/urban-wifi-capture-anonymous.zip")
CAPTURE_CHECKSUM = Path("downloads/urban-wifi-capture-anonymous.sha256")
SYNTHETIC_ARCHIVE = Path("downloads/urban-wifi-synthetic-pipeline.zip")
SYNTHETIC_CHECKSUM = Path("downloads/urban-wifi-synthetic-pipeline.sha256")
REQUIRED_RESOURCES = (
    CAPTURE_ARCHIVE,
    CAPTURE_CHECKSUM,
    SYNTHETIC_ARCHIVE,
    SYNTHETIC_CHECKSUM,
)

CAPTURE_PREFIX = "capture-scripts/"
CAPTURE_MANIFEST = f"{CAPTURE_PREFIX}MANIFEST.sha256"
CAPTURE_SECURITY_VERIFIER = f"{CAPTURE_PREFIX}tests/test_repository_security.py"
CAPTURE_BUILDER = Path("scripts/docs/build_capture_archive.py")
CAPTURE_SOURCE_ROOT = Path("collector")
CAPTURE_VERIFIER_MARKERS = (
    b"test_no_deployment_secret_file_is_present_in_repository",
    b"test_example_configuration_references_a_file_but_contains_no_key",
)
# The capture code needs fixed, non-observed address vectors to test LAA-bit,
# invalid-source, and cross-language HMAC behavior.  Freeze both their locations
# and counts; any other address-like value remains forbidden.
CAPTURE_RAW_TEST_VECTOR_COUNTS: Mapping[str, Counter[bytes]] = {
    "capture-scripts/README.md": Counter(
        {b"aa:bb:cc:dd:ee:ff": 1}
    ),
    "capture-scripts/src/urban_wifi_capture/cli.py": Counter(
        {b"aa:bb:cc:dd:ee:ff": 2}
    ),
    "capture-scripts/tests/test_database.py": Counter(
        {b"aa:bb:cc:dd:ee:ff": 3, b"a8:bb:cc:dd:ee:ff": 1}
    ),
    "capture-scripts/tests/test_identifiers.py": Counter(
        {
            b"aa:bb:cc:dd:ee:ff": 2,
            b"a8:bb:cc:dd:ee:ff": 6,
            b"00:00:00:00:00:00": 1,
            b"ff:ff:ff:ff:ff:ff": 1,
            b"01:00:5e:00:00:01": 1,
        }
    ),
}

SYNTHETIC_BUILDER = Path("scripts/pipeline/build_synthetic_tutorial_archive.py")
EXPECTED_SYNTHETIC_ARCHIVE_NAME = SYNTHETIC_ARCHIVE.name
EXPECTED_SYNTHETIC_CHECKSUM_NAME = SYNTHETIC_CHECKSUM.name

MAX_BUILD_FILES = 50_000
MAX_ZIP_MEMBERS = 2_000
MAX_ZIP_MEMBER_BYTES = 128 * 1024 * 1024
MAX_ZIP_TOTAL_BYTES = 768 * 1024 * 1024

AUTHOR_IDENTIFIERS = (
    b"juhyeon park",
    b"park, juhyeon",
    b"urbanjuhyeon",
    b"juhyeonpark.com",
)
RAW_MAC_RE = re.compile(
    rb"(?i)(?<![0-9a-f])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f])"
)
SECRET_PATTERNS = (
    (
        "private-key block",
        re.compile(
            rb"(?i)-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----"
        ),
    ),
    ("AWS access token", re.compile(rb"(?<![A-Z0-9])AKIA[0-9A-Z]{16}(?![A-Z0-9])")),
    (
        "GitHub access token",
        re.compile(
            rb"(?i)(?:github_pat_[a-z0-9_]{20,}|gh[opusr]_[a-z0-9_]{20,})"
        ),
    ),
    ("Google API token", re.compile(rb"AIza[0-9A-Za-z_-]{35}")),
    ("Slack access token", re.compile(rb"xox[baprs]-[0-9A-Za-z-]{20,}")),
    (
        "credential-bearing URL",
        re.compile(rb"(?i)https?://[^/\s:@]{1,64}:[^/\s@]{4,}@"),
    ),
    (
        "assigned credential or key material",
        re.compile(
            rb"(?i)(?<![a-z0-9_])"
            rb"(?:api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|"
            rb"password|passwd|private[_-]?key|deployment[_-]?key|release[_-]?key)"
            rb"(?![a-z0-9_-])\s*[\"']?\s*[:=]\s*[\"']?"
            rb"(?:[0-9a-f]{32,}|[a-z0-9+/=_-]{24,})"
        ),
    ),
)
LEGACY_PATTERNS = (
    re.compile(
        rb"(?is)\bsha(?:-?256)?\b.{0,96}"
        rb"\b(?:first|leading|prefix|truncat[a-z]*)\b.{0,40}"
        rb"\b(?:16[- ]?(?:hex|character|digit)|64[- ]?bit)"
    ),
    re.compile(
        rb"(?is)\b(?:first|leading|prefix|truncat[a-z]*)\b.{0,40}"
        rb"\b(?:16[- ]?(?:hex|character|digit)|64[- ]?bit)\b.{0,96}"
        rb"\bsha(?:-?256)?\b"
    ),
    re.compile(rb"(?i)(?:_legacy_identifier_hash\.r|legacy_hash_identifier\s*\()"),
    re.compile(
        rb"(?is)\b(?:use|uses|using|apply|applies|create|creates|store|stores|"
        rb"write|writes|replace|replaces|convert|converts)\b.{0,100}"
        rb"\b(?:unkeyed|unsalted)\b.{0,40}\bsha(?:-?256)?\b"
    ),
)
LEGACY_CONTEXT_EXEMPTIONS = (
    b"historical",
    b"legacy",
    b"retired",
    b"former",
    b"no longer",
    b"do not use",
    b"must not use",
    b"never use",
)

FORBIDDEN_FILE_SUFFIXES = (
    ".key",
    ".pem",
    ".p12",
    ".pfx",
    ".secret",
    ".credentials",
    ".pcap",
    ".pcapng",
)
FORBIDDEN_FILE_NAMES = frozenset(
    {
        ".env",
        "credentials.json",
        "secrets.json",
        "id_dsa",
        "id_ed25519",
        "id_ecdsa",
        "id_rsa",
    }
)
MANIFEST_LINE_RE = re.compile(
    r"^([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._/-]*)$"
)


class OnlineBookValidationError(RuntimeError):
    """Raised when a rendered book violates the publication contract."""


@dataclass(frozen=True)
class VerificationSummary:
    mode: str
    files: int
    html_files: int
    local_references: int
    capture_sha256: str
    synthetic_sha256: str


class _ReferenceParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.references: list[tuple[str, str]] = []
        self.has_base_element = False
        self.has_identity_metadata = False

    def handle_starttag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        if tag.lower() == "base":
            self.has_base_element = True
        attributes = {
            name.lower(): value.strip() if value is not None else ""
            for name, value in attrs
        }
        if tag.lower() == "meta":
            metadata_name = (
                attributes.get("name")
                or attributes.get("property")
                or attributes.get("itemprop")
                or ""
            ).lower()
            if (
                metadata_name == "author"
                or metadata_name.startswith("citation_author")
                or metadata_name in {"article:author", "og:url", "twitter:url"}
            ):
                self.has_identity_metadata = True
        if tag.lower() == "link" and "canonical" in {
            item.lower() for item in attributes.get("rel", "").split()
        }:
            self.has_identity_metadata = True
        if any(
            name in attributes
            for name in ("data-repo-url", "data-site-url", "data-github-url")
        ):
            self.has_identity_metadata = True
        for name, value in attrs:
            if name.lower() in {"href", "src"} and value is not None:
                self.references.append((name.lower(), value))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _relative_label(path: Path, root: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return path.name


def _safe_member_name(name: str) -> PurePosixPath:
    path = PurePosixPath(name)
    if (
        not name
        or "\x00" in name
        or "\\" in name
        or name.endswith("/")
        or path.is_absolute()
        or path.as_posix() != name
        or ".." in path.parts
        or "" in path.parts
    ):
        raise OnlineBookValidationError("ZIP contains an unsafe member path")
    lowered_parts = tuple(part.lower() for part in path.parts)
    if any(part.startswith(".git") for part in lowered_parts):
        raise OnlineBookValidationError("ZIP contains Git metadata")
    lowered_name = path.name.lower()
    if lowered_name in FORBIDDEN_FILE_NAMES or lowered_name.endswith(
        FORBIDDEN_FILE_SUFFIXES
    ):
        raise OnlineBookValidationError("ZIP contains a credential/key-like file")
    return path


def _scan_secret_patterns(data: bytes) -> str | None:
    for category, pattern in SECRET_PATTERNS:
        if pattern.search(data):
            return category
    return None


def _has_active_legacy_wording(data: bytes) -> bool:
    lowered = data.lower()
    for pattern in LEGACY_PATTERNS:
        for match in pattern.finditer(data):
            start = max(0, match.start() - 180)
            end = min(len(data), match.end() + 180)
            context = lowered[start:end]
            if any(marker in context for marker in LEGACY_CONTEXT_EXEMPTIONS):
                continue
            return True
    return False


def _scan_rendered_bytes(data: bytes, *, anonymous: bool) -> str | None:
    lowered = data.lower()
    if anonymous and any(marker in lowered for marker in AUTHOR_IDENTIFIERS):
        return "author-identifying string or URL"
    if RAW_MAC_RE.search(data):
        return "raw MAC-like value"
    secret = _scan_secret_patterns(data)
    if secret is not None:
        return secret
    if _has_active_legacy_wording(data):
        return "active SHA16 or legacy identifier-hash wording"
    return None


def _scan_archive_payload(
    payload: dict[str, bytes],
    *,
    synthetic_test_key: bytes | None = None,
    synthetic_key_member: str | None = None,
    allowed_raw_mac_counts: Mapping[str, Counter[bytes]] | None = None,
) -> None:
    total_test_key_occurrences = 0
    allowed_raw_mac_counts = allowed_raw_mac_counts or {}
    if not set(allowed_raw_mac_counts).issubset(payload):
        raise OnlineBookValidationError(
            "ZIP lacks a file declared by its raw-address test-vector allowlist"
        )
    for name, data in payload.items():
        _safe_member_name(name)
        lowered = data.lower()
        if any(marker in lowered for marker in AUTHOR_IDENTIFIERS):
            raise OnlineBookValidationError(
                f"ZIP member contains an author-identifying string or URL: {name}"
            )
        raw_mac_counts = Counter(
            match.group(0).lower() for match in RAW_MAC_RE.finditer(data)
        )
        if raw_mac_counts != allowed_raw_mac_counts.get(name, Counter()):
            raise OnlineBookValidationError(
                f"ZIP member contains a raw MAC-like value: {name}"
            )
        secret = _scan_secret_patterns(data)
        if secret is not None:
            raise OnlineBookValidationError(
                f"ZIP member contains {secret}: {name}"
            )
        if synthetic_test_key is not None:
            occurrences = data.count(synthetic_test_key)
            total_test_key_occurrences += occurrences
            if occurrences and name != synthetic_key_member:
                raise OnlineBookValidationError(
                    "synthetic public test-only key occurs outside its fixture manifest"
                )
    if synthetic_test_key is not None and total_test_key_occurrences != 1:
        raise OnlineBookValidationError(
            "synthetic public test-only key must occur exactly once in its fixture manifest"
        )


def _read_safe_zip(archive: Path) -> dict[str, bytes]:
    try:
        source = zipfile.ZipFile(archive, "r")
    except (OSError, zipfile.BadZipFile) as exc:
        raise OnlineBookValidationError(
            f"required ZIP is unreadable: {archive.name}"
        ) from exc
    with source:
        infos = source.infolist()
        if not infos or len(infos) > MAX_ZIP_MEMBERS:
            raise OnlineBookValidationError("ZIP member count is outside the contract")
        names = [info.filename for info in infos]
        if len(names) != len(set(names)):
            raise OnlineBookValidationError("ZIP contains duplicate member names")
        total_size = 0
        for info in infos:
            _safe_member_name(info.filename)
            mode = (info.external_attr >> 16) & 0xFFFF
            if (
                info.is_dir()
                or info.flag_bits & 0x1
                or stat.S_IFMT(mode) == stat.S_IFLNK
                or info.file_size > MAX_ZIP_MEMBER_BYTES
            ):
                raise OnlineBookValidationError(
                    f"ZIP member metadata is unsafe: {info.filename}"
                )
            total_size += info.file_size
        if total_size > MAX_ZIP_TOTAL_BYTES:
            raise OnlineBookValidationError("ZIP uncompressed size is outside the contract")
        if source.comment:
            raise OnlineBookValidationError("ZIP archive comment is forbidden")
        payload: dict[str, bytes] = {}
        try:
            for info in infos:
                payload[info.filename] = source.read(info)
        except (OSError, RuntimeError, zipfile.BadZipFile) as exc:
            raise OnlineBookValidationError("ZIP member integrity check failed") from exc
    return payload


def _parse_checksum(checksum: Path, archive: Path) -> str:
    try:
        text = checksum.read_text(encoding="ascii")
    except (OSError, UnicodeDecodeError) as exc:
        raise OnlineBookValidationError(
            f"checksum sidecar is unreadable: {checksum.name}"
        ) from exc
    match = re.fullmatch(r"([0-9a-f]{64})  ([^\r\n]+)\n", text)
    if match is None or match.group(2) != archive.name:
        raise OnlineBookValidationError(
            f"checksum sidecar has invalid format or filename: {checksum.name}"
        )
    actual = sha256_file(archive)
    if match.group(1) != actual:
        raise OnlineBookValidationError(
            f"checksum sidecar does not match archive: {archive.name}"
        )
    return actual


def _parse_capture_manifest(data: bytes) -> dict[str, str]:
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError as exc:
        raise OnlineBookValidationError("capture internal manifest is not ASCII") from exc
    if not text.endswith("\n") or "\r" in text:
        raise OnlineBookValidationError(
            "capture internal manifest must use final-LF line endings"
        )
    entries: dict[str, str] = {}
    names: list[str] = []
    for line in text.splitlines():
        match = MANIFEST_LINE_RE.fullmatch(line)
        if match is None:
            raise OnlineBookValidationError("capture internal manifest is malformed")
        digest, name = match.groups()
        _safe_member_name(name)
        if name in entries:
            raise OnlineBookValidationError(
                "capture internal manifest contains a duplicate member"
            )
        entries[name] = digest
        names.append(name)
    if names != sorted(names):
        raise OnlineBookValidationError(
            "capture internal manifest entries are not sorted"
        )
    return entries


def _load_capture_builder(repository_root: Path) -> ModuleType:
    path = repository_root / CAPTURE_BUILDER
    if not path.is_file() or path.is_symlink():
        raise OnlineBookValidationError("capture archive builder is missing")
    spec = importlib.util.spec_from_file_location(
        "online_book_capture_archive_builder", path
    )
    if spec is None or spec.loader is None:
        raise OnlineBookValidationError("cannot load capture archive builder")
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception as exc:
        raise OnlineBookValidationError("cannot initialize capture archive builder") from exc
    required = (
        "ARCHIVE_PREFIX",
        "INTERNAL_MANIFEST",
        "DEFAULT_ARCHIVE",
        "DEFAULT_CHECKSUM",
        "expected_artifacts",
    )
    if any(not hasattr(module, name) for name in required):
        raise OnlineBookValidationError("capture archive builder contract is incomplete")
    if (
        module.ARCHIVE_PREFIX != CAPTURE_PREFIX
        or f"{module.ARCHIVE_PREFIX}{module.INTERNAL_MANIFEST}" != CAPTURE_MANIFEST
        or Path(module.DEFAULT_ARCHIVE).name != CAPTURE_ARCHIVE.name
        or Path(module.DEFAULT_CHECKSUM).name != CAPTURE_CHECKSUM.name
    ):
        raise OnlineBookValidationError(
            "capture archive resource names differ from its builder contract"
        )
    return module


def _verify_capture_source_rebuild(
    archive: Path, checksum: Path, repository_root: Path
) -> None:
    module = _load_capture_builder(repository_root)
    source_root = repository_root / CAPTURE_SOURCE_ROOT
    try:
        expected_archive, expected_checksum = module.expected_artifacts(
            source_root, archive.name
        )
    except Exception as exc:
        raise OnlineBookValidationError(
            "capture ZIP could not be rebuilt from canonical source"
        ) from exc
    if not isinstance(expected_archive, bytes) or not isinstance(expected_checksum, bytes):
        raise OnlineBookValidationError(
            "capture archive builder returned invalid artifact bytes"
        )
    try:
        actual_archive = archive.read_bytes()
        actual_checksum = checksum.read_bytes()
    except OSError as exc:
        raise OnlineBookValidationError(
            "capture ZIP or checksum is unreadable during source comparison"
        ) from exc
    if actual_archive != expected_archive or actual_checksum != expected_checksum:
        raise OnlineBookValidationError(
            "capture ZIP/checksum drift from the canonical collector source"
        )


def _verify_capture_archive(
    archive: Path, checksum: Path, repository_root: Path | None = None
) -> str:
    digest = _parse_checksum(checksum, archive)
    payload = _read_safe_zip(archive)
    if CAPTURE_MANIFEST not in payload:
        raise OnlineBookValidationError("capture ZIP lacks its internal manifest")
    if any(not name.startswith(CAPTURE_PREFIX) for name in payload):
        raise OnlineBookValidationError("capture ZIP member escapes its fixed prefix")
    entries = _parse_capture_manifest(payload[CAPTURE_MANIFEST])
    expected = {
        name.removeprefix(CAPTURE_PREFIX)
        for name in payload
        if name != CAPTURE_MANIFEST
    }
    if set(entries) != expected:
        raise OnlineBookValidationError(
            "capture internal manifest does not cover the exact ZIP member set"
        )
    for relative_name, expected_hash in entries.items():
        actual = hashlib.sha256(
            payload[f"{CAPTURE_PREFIX}{relative_name}"]
        ).hexdigest()
        if actual != expected_hash:
            raise OnlineBookValidationError(
                "capture internal manifest hash does not match a ZIP member"
            )
    if CAPTURE_SECURITY_VERIFIER not in payload or not all(
        marker in payload[CAPTURE_SECURITY_VERIFIER]
        for marker in CAPTURE_VERIFIER_MARKERS
    ):
        raise OnlineBookValidationError(
            "capture ZIP lacks its manifest-covered repository security verifier"
        )
    _scan_archive_payload(
        payload, allowed_raw_mac_counts=CAPTURE_RAW_TEST_VECTOR_COUNTS
    )
    if repository_root is not None:
        _verify_capture_source_rebuild(archive, checksum, repository_root)
    return digest


def _load_synthetic_verifier(repository_root: Path) -> ModuleType:
    path = repository_root / SYNTHETIC_BUILDER
    if not path.is_file() or path.is_symlink():
        raise OnlineBookValidationError("synthetic archive verifier is missing")
    spec = importlib.util.spec_from_file_location(
        "online_book_synthetic_archive_verifier", path
    )
    if spec is None or spec.loader is None:
        raise OnlineBookValidationError("cannot load synthetic archive verifier")
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception as exc:
        raise OnlineBookValidationError("cannot initialize synthetic archive verifier") from exc
    required = (
        "ARCHIVE_NAME",
        "CHECKSUM_NAME",
        "FIXTURE_MANIFEST",
        "PUBLIC_TEST_KEY",
        "verify_archive",
        "verify_checksum",
    )
    if any(not hasattr(module, name) for name in required):
        raise OnlineBookValidationError("synthetic archive verifier contract is incomplete")
    if (
        module.ARCHIVE_NAME != EXPECTED_SYNTHETIC_ARCHIVE_NAME
        or module.CHECKSUM_NAME != EXPECTED_SYNTHETIC_CHECKSUM_NAME
    ):
        raise OnlineBookValidationError(
            "synthetic archive resource names differ from its own verifier"
        )
    return module


def _verify_synthetic_archive(
    archive: Path, checksum: Path, repository_root: Path
) -> str:
    module = _load_synthetic_verifier(repository_root)
    try:
        payload = module.verify_archive(archive)
        digest = module.verify_checksum(archive, checksum)
    except Exception as exc:
        raise OnlineBookValidationError(
            "synthetic ZIP failed its own manifest/verifier contract"
        ) from exc
    if not isinstance(payload, dict) or not all(
        isinstance(name, str) and isinstance(data, bytes)
        for name, data in payload.items()
    ):
        raise OnlineBookValidationError(
            "synthetic archive verifier returned an invalid payload"
        )
    # The verifier above already checks this exception.  Rechecking here makes
    # the online-book policy explicit and prevents the exception from widening.
    _scan_archive_payload(
        payload,
        synthetic_test_key=module.PUBLIC_TEST_KEY,
        synthetic_key_member=module.FIXTURE_MANIFEST,
    )
    if digest != sha256_file(archive):
        raise OnlineBookValidationError(
            "synthetic archive verifier returned an inconsistent checksum"
        )
    return digest


def verify_required_archives(build_root: Path, repository_root: Path) -> tuple[str, str]:
    for relative in REQUIRED_RESOURCES:
        path = build_root / relative
        if not path.is_file() or path.is_symlink():
            raise OnlineBookValidationError(
                f"required rendered resource is missing: {relative.as_posix()}"
            )
    capture = _verify_capture_archive(
        build_root / CAPTURE_ARCHIVE,
        build_root / CAPTURE_CHECKSUM,
        repository_root,
    )
    synthetic = _verify_synthetic_archive(
        build_root / SYNTHETIC_ARCHIVE,
        build_root / SYNTHETIC_CHECKSUM,
        repository_root,
    )
    return capture, synthetic


def _decode_local_path(value: str) -> str:
    decoded = value
    for _ in range(3):
        next_value = unquote(decoded)
        if next_value == decoded:
            break
        decoded = next_value
    return decoded


def _resolve_local_reference(
    value: str, *, page: Path, build_root: Path
) -> Path | None:
    value = value.strip()
    if not value or value.startswith("#"):
        return None
    if any(ord(character) < 32 for character in value):
        raise OnlineBookValidationError(
            f"HTML contains a control character in href/src: {_relative_label(page, build_root)}"
        )
    if re.match(r"(?i)^[a-z]:[\\/]", value):
        raise OnlineBookValidationError(
            f"HTML contains an absolute local href/src: {_relative_label(page, build_root)}"
        )
    try:
        parsed = urlsplit(value)
    except ValueError as exc:
        raise OnlineBookValidationError(
            f"HTML contains a malformed href/src: {_relative_label(page, build_root)}"
        ) from exc
    scheme = parsed.scheme.lower()
    if scheme:
        if scheme in {"http", "https", "mailto", "tel", "data"}:
            return None
        raise OnlineBookValidationError(
            f"HTML uses a forbidden href/src scheme: {_relative_label(page, build_root)}"
        )
    if parsed.netloc:
        return None
    path_text = _decode_local_path(parsed.path)
    if not path_text:
        return page
    if (
        path_text.startswith(('/', '\\'))
        or "\\" in path_text
        or re.match(r"(?i)^[a-z]:", path_text)
    ):
        raise OnlineBookValidationError(
            f"HTML contains an absolute local href/src: {_relative_label(page, build_root)}"
        )
    pure = PurePosixPath(path_text)
    if pure.is_absolute() or ".." in pure.parts or "" in pure.parts:
        raise OnlineBookValidationError(
            f"HTML contains a traversal href/src: {_relative_label(page, build_root)}"
        )
    target = page.parent.joinpath(*pure.parts).resolve(strict=False)
    try:
        target.relative_to(build_root)
    except ValueError as exc:
        raise OnlineBookValidationError(
            f"HTML href/src resolves outside the build root: {_relative_label(page, build_root)}"
        ) from exc
    if not target.exists() or target.is_symlink():
        raise OnlineBookValidationError(
            f"HTML contains a missing local href/src target: {_relative_label(page, build_root)}"
        )
    if target.is_dir():
        index = target / "index.html"
        if not index.is_file() or index.is_symlink():
            raise OnlineBookValidationError(
                f"HTML directory href lacks index.html: {_relative_label(page, build_root)}"
            )
        return index.resolve(strict=True)
    if not target.is_file():
        raise OnlineBookValidationError(
            f"HTML href/src target is not a regular file: {_relative_label(page, build_root)}"
        )
    return target.resolve(strict=True)


def _collect_files(build_root: Path) -> list[Path]:
    paths = sorted(build_root.rglob("*"))
    if len(paths) > MAX_BUILD_FILES:
        raise OnlineBookValidationError("rendered build contains too many paths")
    for path in paths:
        if path.is_symlink():
            raise OnlineBookValidationError(
                f"rendered build contains a symbolic link: {_relative_label(path, build_root)}"
            )
        relative_parts = path.relative_to(build_root).parts
        if any(part.lower().startswith(".git") for part in relative_parts):
            raise OnlineBookValidationError("rendered build contains Git metadata")
        if path.is_file():
            lowered_name = path.name.lower()
            if lowered_name in FORBIDDEN_FILE_NAMES or lowered_name.endswith(
                FORBIDDEN_FILE_SUFFIXES
            ):
                raise OnlineBookValidationError(
                    "rendered build contains a credential/key-like file"
                )
    return [path for path in paths if path.is_file()]


def verify_online_book(
    build_root: Path, *, mode: str, repository_root: Path
) -> VerificationSummary:
    if mode not in {"public", "anonymous"}:
        raise OnlineBookValidationError("mode must be public or anonymous")
    if build_root.is_symlink():
        raise OnlineBookValidationError("build root must not be a symbolic link")
    try:
        build_root = build_root.resolve(strict=True)
        repository_root = repository_root.resolve(strict=True)
    except OSError as exc:
        raise OnlineBookValidationError("build or repository root is missing") from exc
    if not build_root.is_dir() or not repository_root.is_dir():
        raise OnlineBookValidationError("build and repository roots must be directories")

    files = _collect_files(build_root)
    if not (build_root / "index.html").is_file():
        raise OnlineBookValidationError("rendered book lacks index.html")
    html_files = [path for path in files if path.suffix.lower() in {".html", ".htm"}]
    if not html_files:
        raise OnlineBookValidationError("rendered book contains no HTML files")

    for path in files:
        if path.suffix.lower() == ".zip":
            continue
        try:
            data = path.read_bytes()
        except OSError as exc:
            raise OnlineBookValidationError(
                f"cannot read rendered file: {_relative_label(path, build_root)}"
            ) from exc
        finding = _scan_rendered_bytes(data, anonymous=mode == "anonymous")
        if finding is not None:
            raise OnlineBookValidationError(
                f"rendered file contains {finding}: {_relative_label(path, build_root)}"
            )

    local_targets: set[Path] = set()
    reference_count = 0
    for page in html_files:
        parser = _ReferenceParser()
        try:
            parser.feed(page.read_text(encoding="utf-8"))
            parser.close()
        except (OSError, UnicodeDecodeError) as exc:
            raise OnlineBookValidationError(
                f"rendered HTML is not valid UTF-8: {_relative_label(page, build_root)}"
            ) from exc
        if parser.has_base_element:
            raise OnlineBookValidationError(
                f"rendered HTML contains a base element: {_relative_label(page, build_root)}"
            )
        if mode == "anonymous" and parser.has_identity_metadata:
            raise OnlineBookValidationError(
                "anonymous HTML contains author, canonical-site, or repository metadata: "
                f"{_relative_label(page, build_root)}"
            )
        for _, value in parser.references:
            reference_count += 1
            target = _resolve_local_reference(
                value, page=page, build_root=build_root
            )
            if target is not None:
                local_targets.add(target)

    for relative in REQUIRED_RESOURCES:
        required = (build_root / relative).resolve(strict=False)
        if required not in local_targets:
            raise OnlineBookValidationError(
                f"required resource is not linked by rendered HTML: {relative.as_posix()}"
            )

    capture_hash, synthetic_hash = verify_required_archives(
        build_root, repository_root
    )
    return VerificationSummary(
        mode=mode,
        files=len(files),
        html_files=len(html_files),
        local_references=reference_count,
        capture_sha256=capture_hash,
        synthetic_sha256=synthetic_hash,
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_root", type=Path)
    parser.add_argument("--mode", choices=("public", "anonymous"), required=True)
    parser.add_argument(
        "--repository-root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
    )
    return parser


def main() -> int:
    args = _parser().parse_args()
    try:
        summary = verify_online_book(
            args.build_root,
            mode=args.mode,
            repository_root=args.repository_root,
        )
    except OnlineBookValidationError as exc:
        raise SystemExit(f"online-book verification failed: {exc}") from exc
    print(
        "online-book verification passed: "
        f"mode={summary.mode}, files={summary.files}, "
        f"html={summary.html_files}, href/src={summary.local_references}"
    )
    print(f"capture ZIP SHA-256: {summary.capture_sha256}")
    print(f"synthetic ZIP SHA-256: {summary.synthetic_sha256}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
