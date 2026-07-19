import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from urban_wifi_capture.collector import (
    _SignalRequest,
    _capture_interface_loop,
    _shutdown_child_failure,
    _unexpected_child_failure,
)
from urban_wifi_capture.config import InterfaceConfig


class _FakeStopEvent:
    def __init__(self):
        self.stopped = False
        self.waits = []

    def is_set(self):
        return self.stopped

    def wait(self, timeout):
        self.waits.append(timeout)
        self.stopped = True
        return True


class _FakeCapture:
    def __init__(self):
        self.nonblocking = []

    def datalink(self):
        return 127

    def setfilter(self, _expression):
        return None

    def setnonblock(self, value):
        self.nonblocking.append(value)

    def next(self):
        return None, None

    def stats(self):
        return 0, 0, 0


class _FakeQueue:
    def __init__(self):
        self.items = []

    def put(self, item, timeout=None):
        self.items.append(item)


class CollectorLifecycleTests(unittest.TestCase):
    def test_signal_handler_only_records_the_requested_signal(self):
        request = _SignalRequest()
        request(15, None)
        self.assertEqual(request.signum, 15)

    def test_quiet_capture_uses_nonblocking_reads_and_observes_stop_event(self):
        capture = _FakeCapture()
        stop_event = _FakeStopEvent()
        record_queue = _FakeQueue()
        pcapy = SimpleNamespace(open_live=lambda *_args: capture)

        with patch.dict(sys.modules, {"pcapy": pcapy}):
            _capture_interface_loop(
                InterfaceConfig(physical="wlan0", monitor="ucap0", channel=1),
                "sensor-a01",
                "unist26",
                b"k" * 32,
                record_queue,
                stop_event,
            )

        self.assertEqual(capture.nonblocking, [1])
        self.assertEqual(stop_event.waits, [0.05])
        self.assertEqual(len(record_queue.items), 1)

    def test_writer_exit_is_detected_before_producer_exit(self):
        writer = SimpleNamespace(name="sqlite-writer", exitcode=2)
        producer = SimpleNamespace(name="capture-mon0", exitcode=3)
        self.assertEqual(
            _unexpected_child_failure(writer, [producer]),
            "SQLite writer exited with code 2",
        )

    def test_clean_early_writer_exit_is_still_unexpected(self):
        writer = SimpleNamespace(name="sqlite-writer", exitcode=0)
        self.assertEqual(
            _unexpected_child_failure(writer, []),
            "SQLite writer stopped unexpectedly",
        )

    def test_producer_exit_is_detected(self):
        writer = SimpleNamespace(name="sqlite-writer", exitcode=None)
        producer = SimpleNamespace(name="capture-mon0", exitcode=1)
        self.assertEqual(
            _unexpected_child_failure(writer, [producer]),
            "capture-mon0 exited with code 1",
        )

    def test_running_children_have_no_failure(self):
        writer = SimpleNamespace(name="sqlite-writer", exitcode=None)
        producer = SimpleNamespace(name="capture-mon0", exitcode=None)
        self.assertIsNone(_unexpected_child_failure(writer, [producer]))

    def test_requested_stop_allows_clean_writer_exit(self):
        writer = SimpleNamespace(name="sqlite-writer", exitcode=0)
        producer = SimpleNamespace(name="capture-mon0", exitcode=0)
        self.assertIsNone(_shutdown_child_failure(writer, [producer]))

    def test_requested_stop_preserves_joined_producer_failure(self):
        writer = SimpleNamespace(name="sqlite-writer", exitcode=0)
        producer = SimpleNamespace(name="capture-mon0", exitcode=1)
        self.assertEqual(
            _shutdown_child_failure(writer, [producer]),
            "capture-mon0 exited with code 1",
        )


if __name__ == "__main__":
    unittest.main()
