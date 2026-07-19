"""Multiprocess packet capture with a single bounded SQLite writer."""

from __future__ import annotations

import logging
import multiprocessing as mp
import os
import queue
import signal
import stat
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, Sequence

from .config import CaptureConfig, InterfaceConfig
from .database import connect_database, writer_loop
from .frames import parse_frame
from .identifiers import Pseudonymizer
from .model import CaptureSummary

LOGGER = logging.getLogger(__name__)
DLT_IEEE802_11_RADIO = 127
CAPTURE_DATA_ROOT = Path("/var/lib/urban-sensing")


class _SignalRequest:
    """Record a service-stop signal without acquiring multiprocessing locks."""

    def __init__(self) -> None:
        self.signum: Optional[int] = None

    def __call__(self, signum: int, _frame: object) -> None:
        # Python signal handlers run on the main thread between bytecode
        # instructions. Keep this handler lock-free: calling Event.set() here
        # can deadlock if SIGTERM interrupts Event.wait().
        self.signum = signum


def _utc_timestamp(seconds: int, microseconds: int) -> str:
    captured = datetime.fromtimestamp(
        float(seconds) + float(microseconds) / 1_000_000.0,
        tz=timezone.utc,
    )
    return captured.isoformat(timespec="microseconds").replace("+00:00", "Z")


def _capture_interface_loop(
    item: InterfaceConfig,
    sensor_name: str,
    deployment_id: str,
    pseudonymization_key: bytes,
    record_queue: object,
    stop_event: object,
) -> None:
    pseudonymizer = Pseudonymizer(deployment_id, pseudonymization_key)
    try:
        import pcapy

        # A 256-byte snapshot contains radiotap and 802.11 headers while
        # deliberately truncating higher-layer payloads in process memory.
        capture = pcapy.open_live(item.monitor, 256, 0, 100)
        if capture.datalink() != DLT_IEEE802_11_RADIO:
            raise RuntimeError(f"{item.monitor} does not provide radiotap 802.11 frames")
        capture.setfilter("type mgt or type data")
        # libpcap read timeouts are not guaranteed to wake pcap_next_ex() on
        # every Linux capture driver. Non-blocking reads let the worker check
        # the shared stop event promptly even when an interface is quiet.
        capture.setnonblock(1)
    except Exception as exc:
        LOGGER.error(
            "cannot open configured monitor interface %s: %s",
            item.monitor,
            type(exc).__name__,
        )
        raise

    dropped = 0
    emitted = 0
    filtered = 0
    try:
        while not stop_event.is_set():  # type: ignore[attr-defined]
            try:
                header, payload = capture.next()
            except KeyboardInterrupt:
                break
            except Exception as exc:
                LOGGER.error("capture read failed on %s: %s", item.monitor, type(exc).__name__)
                raise RuntimeError(f"capture read failed on {item.monitor}") from exc

            if header is None or payload is None:
                # Avoid a busy loop in non-blocking mode while remaining
                # responsive to SIGTERM relayed through the shared event.
                stop_event.wait(0.05)  # type: ignore[attr-defined]
                continue
            seconds, microseconds = header.getts()
            record = parse_frame(
                payload,
                timestamp=_utc_timestamp(seconds, microseconds),
                channel=item.channel,
                sensor_name=sensor_name,
                pseudonymizer=pseudonymizer,
            )
            # No raw bytes or raw addresses survive beyond parse_frame.
            del payload
            if record is None:
                filtered += 1
                continue
            try:
                record_queue.put(record, timeout=0.25)  # type: ignore[attr-defined]
            except queue.Full:
                dropped += 1
                if dropped == 1 or dropped % 1000 == 0:
                    LOGGER.warning(
                        "bounded record queue full on %s; dropped=%d",
                        item.monitor,
                        dropped,
                    )
            else:
                emitted += 1
    finally:
        try:
            received, pcap_dropped, interface_dropped = (int(value) for value in capture.stats())
        except Exception:
            received, pcap_dropped, interface_dropped = -1, -1, -1
        summary = CaptureSummary(
            interface=item.monitor,
            channel=item.channel,
            pcap_received=received,
            pcap_dropped=pcap_dropped,
            interface_dropped=interface_dropped,
            queue_dropped=dropped,
            records_emitted=emitted,
            records_filtered=filtered,
            completed_at=datetime.now(timezone.utc)
            .isoformat(timespec="microseconds")
            .replace("+00:00", "Z"),
        )
        record_queue.put(summary)  # type: ignore[attr-defined]
        LOGGER.info(
            "capture summary interface=%s recv=%d pcap_drop=%d if_drop=%d "
            "queue_drop=%d emitted=%d filtered=%d",
            item.monitor,
            received,
            pcap_dropped,
            interface_dropped,
            dropped,
            emitted,
            filtered,
        )


def _capture_interface(
    item: InterfaceConfig,
    sensor_name: str,
    deployment_id: str,
    pseudonymization_key: bytes,
    record_queue: object,
    stop_event: object,
) -> None:
    """Run one producer and flush its FIFO completion marker."""

    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    try:
        _capture_interface_loop(
            item,
            sensor_name,
            deployment_id,
            pseudonymization_key,
            record_queue,
            stop_event,
        )
    finally:
        # multiprocessing.Queue preserves per-producer FIFO order. The writer
        # therefore receives every record from this producer before this marker.
        record_queue.put(None)  # type: ignore[attr-defined]
        close = getattr(record_queue, "close", None)
        join_thread = getattr(record_queue, "join_thread", None)
        if callable(close):
            close()
        if callable(join_thread):
            join_thread()


def _writer_process(
    database_path: Path,
    record_queue: object,
    batch_size: int,
    producer_count: int,
    deployment_id: str,
) -> None:
    """Run the writer without inheriting terminal or service-stop signals."""

    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    writer_loop(
        database_path, record_queue, batch_size, producer_count, deployment_id=deployment_id
    )


def _database_name(sensor_name: str) -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    return f"raw_wifi_{sensor_name}_{stamp}.sqlite3"


def _validated_runtime_data_dir(path: Path) -> Path:
    return validate_runtime_data_dir(path, for_capture=True)


def validate_runtime_data_dir(path: Path, *, for_capture: bool = False) -> Path:
    """Validate the production state path without mutating its permissions."""

    if os.name != "posix":
        raise PermissionError("runtime data-directory validation requires Linux")

    import pwd

    try:
        service_uid = pwd.getpwnam("urban-sensing").pw_uid
    except KeyError as exc:
        raise PermissionError("urban-sensing service account does not exist") from exc
    if for_capture and os.geteuid() == 0:
        raise PermissionError("packet capture must not run as root; use the hardened systemd unit")
    if for_capture and os.geteuid() != service_uid:
        raise PermissionError("packet capture must run as the urban-sensing service account")

    absolute = Path(path).absolute()
    for candidate in (absolute, *absolute.parents):
        if candidate.is_symlink():
            raise PermissionError(f"capture data path contains a symlink: {candidate}")
    try:
        resolved = absolute.resolve(strict=True)
    except OSError as exc:
        raise PermissionError(f"capture data directory must be pre-created: {absolute}") from exc

    try:
        allowed_root = CAPTURE_DATA_ROOT.resolve(strict=True)
    except OSError as exc:
        raise PermissionError(f"capture state root does not exist: {CAPTURE_DATA_ROOT}") from exc
    try:
        resolved.relative_to(allowed_root)
    except ValueError as exc:
        raise PermissionError(f"capture data directory must be under {allowed_root}") from exc
    details = resolved.lstat()
    if not stat.S_ISDIR(details.st_mode):
        raise PermissionError("capture data path must be a real directory")
    if details.st_uid != service_uid:
        raise PermissionError("capture data directory must be owned by urban-sensing")
    if details.st_mode & 0o777 != 0o700:
        raise PermissionError("capture data directory mode must be 0700")
    return resolved


def _unexpected_child_failure(writer: object, producers: Sequence[object]) -> Optional[str]:
    """Return a diagnostic when a child exits before shutdown is requested."""

    writer_exitcode = writer.exitcode  # type: ignore[attr-defined]
    if writer_exitcode is not None:
        if writer_exitcode == 0:
            return "SQLite writer stopped unexpectedly"
        return f"SQLite writer exited with code {writer_exitcode}"
    for process in producers:
        exitcode = process.exitcode  # type: ignore[attr-defined]
        if exitcode is None:
            continue
        if exitcode == 0:
            return f"{process.name} stopped unexpectedly"  # type: ignore[attr-defined]
        return f"{process.name} exited with code {exitcode}"  # type: ignore[attr-defined]
    return None


def _shutdown_child_failure(writer: object, producers: Sequence[object]) -> Optional[str]:
    """Return only failures after an orderly stop has been requested."""

    writer_exitcode = writer.exitcode  # type: ignore[attr-defined]
    if writer_exitcode not in (None, 0):
        return f"SQLite writer exited with code {writer_exitcode}"
    for process in producers:
        exitcode = process.exitcode  # type: ignore[attr-defined]
        if exitcode not in (None, 0):
            return f"{process.name} exited with code {exitcode}"  # type: ignore[attr-defined]
    return None


def run_capture(config: CaptureConfig) -> Path:
    """Capture until SIGINT/SIGTERM and return the local SQLite path."""

    if config.pseudonymization_key is None:
        raise RuntimeError("capture requires a validated deployment key")
    data_dir = _validated_runtime_data_dir(config.data_dir)
    database_path = data_dir / _database_name(config.sensor_name)
    connection = connect_database(database_path, config.deployment_id)
    connection.close()

    context = mp.get_context("spawn")
    record_queue = context.Queue(maxsize=config.queue_size)
    stop_event = context.Event()
    writer = context.Process(
        target=_writer_process,
        name="sqlite-writer",
        args=(
            database_path,
            record_queue,
            config.batch_size,
            len(config.interfaces),
            config.deployment_id,
        ),
    )
    producers = [
        context.Process(
            target=_capture_interface,
            name=f"capture-{item.monitor}",
            args=(
                item,
                config.sensor_name,
                config.deployment_id,
                config.pseudonymization_key,
                record_queue,
                stop_event,
            ),
        )
        for item in config.interfaces
    ]

    stop_request = _SignalRequest()
    previous_int = signal.signal(signal.SIGINT, stop_request)
    previous_term = signal.signal(signal.SIGTERM, stop_request)
    failure: Optional[str] = None
    writer_started = False
    started_producers = []
    hard_cleanup = False
    try:
        try:
            writer.start()
            writer_started = True
        except Exception as exc:
            failure = f"could not start SQLite writer: {type(exc).__name__}"

        if writer_started:
            for process in producers:
                try:
                    process.start()
                    started_producers.append(process)
                except Exception as exc:
                    failure = f"could not start {process.name}: {type(exc).__name__}"
                    stop_event.set()
                    break

        if writer_started and not failure:
            while stop_request.signum is None and not stop_event.wait(0.25):
                failure = _unexpected_child_failure(writer, started_producers)
                if failure:
                    stop_event.set()
            if stop_request.signum is not None:
                LOGGER.info("received signal %d; stopping capture", stop_request.signum)
    finally:
        stop_event.set()
        deadline = time.monotonic() + 90.0

        # If the sole queue reader has already failed, child feeder threads may
        # block forever. Discard this queue and end non-zero so systemd can
        # restart into a new database; committed SQLite batches remain valid.
        shutdown_failure = _shutdown_child_failure(writer, ()) if writer_started else None
        writer_failed = shutdown_failure is not None
        if writer_failed:
            hard_cleanup = True
            failure = failure or shutdown_failure

        if not hard_cleanup:
            remaining = list(started_producers)
            while remaining and time.monotonic() < deadline:
                if writer.exitcode not in (None, 0):
                    writer_failed = True
                    hard_cleanup = True
                    failure = failure or _unexpected_child_failure(writer, ())
                    break
                for process in tuple(remaining):
                    process.join(timeout=0.2)
                    if not process.is_alive():
                        remaining.remove(process)
            if remaining and not hard_cleanup:
                hard_cleanup = True
                names = ", ".join(process.name for process in remaining)
                failure = failure or f"capture producer shutdown deadline exceeded: {names}"
            if not hard_cleanup:
                failure = failure or _shutdown_child_failure(writer, started_producers)

        if hard_cleanup:
            for process in started_producers:
                if process.is_alive():
                    process.kill()
                process.join(timeout=2.0)
            if writer_started and writer.is_alive():
                writer.kill()
                writer.join(timeout=2.0)
        elif writer_started:
            # Started producers publish their own FIFO completion marker. The
            # parent supplies markers only for configured producers that never
            # started, so the writer's expected count is still satisfied.
            missing_markers = len(producers) - len(started_producers)
            for _ in range(missing_markers):
                marker_sent = False
                while not marker_sent and time.monotonic() < deadline:
                    if writer.exitcode is not None:
                        hard_cleanup = True
                        failure = failure or _unexpected_child_failure(writer, ())
                        break
                    try:
                        record_queue.put(None, timeout=0.5)
                        marker_sent = True
                    except queue.Full:
                        continue

            while not hard_cleanup and writer.is_alive() and time.monotonic() < deadline:
                writer.join(timeout=0.5)
            if writer.is_alive():
                hard_cleanup = True
                failure = failure or "SQLite writer shutdown deadline exceeded"
                writer.kill()
                writer.join(timeout=2.0)
            elif writer.exitcode != 0:
                hard_cleanup = True
                failure = failure or f"SQLite writer exited with code {writer.exitcode}"

        signal.signal(signal.SIGINT, previous_int)
        signal.signal(signal.SIGTERM, previous_term)
        if hard_cleanup or not writer_started:
            record_queue.cancel_join_thread()
        record_queue.close()
        if writer_started and not hard_cleanup:
            record_queue.join_thread()

    if failure:
        raise RuntimeError(failure)
    return database_path
