import unittest
from types import SimpleNamespace

from urban_wifi_capture.frames import parse_frame, record_from_decoded
from urban_wifi_capture.identifiers import Pseudonymizer

PSEUDONYMIZER = Pseudonymizer("DEPLOYMENT_TEST_2026", bytes(range(32)))


def fake_packet(source, *, frame_type=0, subtype=4, strength=-55):
    body = SimpleNamespace(
        src=source,
        dst=bytes.fromhex("102030405060"),
        bssid=bytes.fromhex("a0b0c0d0e0f0"),
    )
    frame = SimpleNamespace(
        type=frame_type,
        subtype=subtype,
        mgmt=body,
        data_frame=body,
        ssid=SimpleNamespace(data=b"Private-Network-Name"),
    )
    return SimpleNamespace(data=frame, ant_sig=SimpleNamespace(db=strength))


class FrameTests(unittest.TestCase):
    def test_token_is_stable_across_sensors_times_and_channels(self):
        packet = fake_packet(bytes.fromhex("a8bbccddeeff"))
        first = record_from_decoded(
            packet,
            timestamp="2026-01-01T00:00:00.000001Z",
            channel=1,
            sensor_name="A01",
            pseudonymizer=PSEUDONYMIZER,
        )
        second = record_from_decoded(
            packet,
            timestamp="2026-01-02T12:34:56.000001Z",
            channel=11,
            sensor_name="A10",
            pseudonymizer=PSEUDONYMIZER,
        )
        self.assertEqual(first.source_address, second.source_address)

    def test_synthetic_radiotap_probe_request_parses_end_to_end(self):
        # Radiotap header with -55 dBm followed by a synthetic probe request.
        # Addresses are test vectors only; no field capture is used as a fixture.
        frame = bytes.fromhex(
            "0000090020000000c940000000ffffffffffffa8bbccddeeffffffffffffff00000000"
        )
        record = parse_frame(
            frame,
            timestamp="2026-01-01T00:00:00.000001Z",
            channel=1,
            sensor_name="A01",
            pseudonymizer=PSEUDONYMIZER,
        )
        self.assertIsNotNone(record)
        self.assertEqual(record.subtype, "probe-request")
        self.assertEqual(record.strength, -55)
        self.assertEqual(
            record.source_address,
            "7ca615b14f2135fed4e8a402b4db14b6",  # pragma: allowlist secret
        )
        self.assertEqual(record.source_address_randomized, 0)

    def test_management_frame_returns_allowlisted_fields_only(self):
        record = record_from_decoded(
            fake_packet(bytes.fromhex("a8bbccddeeff")),
            timestamp="2026-01-01T00:00:00.000001Z",
            channel=1,
            sensor_name="A01",
            pseudonymizer=PSEUDONYMIZER,
        )
        self.assertIsNotNone(record)
        self.assertEqual(
            set(record.__dict__),
            {
                "timestamp",
                "type",
                "subtype",
                "strength",
                "source_address",
                "source_address_randomized",
                "channel",
                "sensor_name",
            },
        )
        self.assertEqual(
            record.source_address,
            "7ca615b14f2135fed4e8a402b4db14b6",  # pragma: allowlist secret
        )
        self.assertEqual(record.source_address_randomized, 0)
        self.assertNotIn("Private-Network-Name", repr(record))
        self.assertNotIn("a8bbccddeeff", repr(record).lower())

    def test_local_source_flag_survives(self):
        record = record_from_decoded(
            fake_packet(bytes.fromhex("aabbccddeeff"), frame_type=2, subtype=8),
            timestamp="2026-01-01T00:00:00.000001Z",
            channel=6,
            sensor_name="A02",
            pseudonymizer=PSEUDONYMIZER,
        )
        self.assertEqual(record.type, "data")
        self.assertEqual(record.source_address_randomized, 1)

    def test_from_ds_frame_is_not_paired_with_logical_source(self):
        frame = bytes.fromhex("0000090020000000c908020000ffffffffffff102030405060a8bbccddeeff0000")
        self.assertIsNone(
            parse_frame(
                frame,
                timestamp="2026-01-01T00:00:00.000001Z",
                channel=6,
                sensor_name="A02",
                pseudonymizer=PSEUDONYMIZER,
            )
        )

    def test_to_ds_frame_keeps_over_air_client_transmitter(self):
        frame = bytes.fromhex("0000090020000000c908010000102030405060a8bbccddeeffffffffffffff0000")
        record = parse_frame(
            frame,
            timestamp="2026-01-01T00:00:00.000001Z",
            channel=6,
            sensor_name="A02",
            pseudonymizer=PSEUDONYMIZER,
        )
        self.assertIsNotNone(record)
        self.assertEqual(record.type, "data")
        self.assertEqual(record.subtype, "data")
        self.assertEqual(record.strength, -55)
        self.assertEqual(
            record.source_address,
            "7ca615b14f2135fed4e8a402b4db14b6",  # pragma: allowlist secret
        )
        self.assertEqual(record.source_address_randomized, 0)

    def test_beacon_invalid_source_and_bad_strength_are_dropped(self):
        cases = (
            fake_packet(bytes.fromhex("a8bbccddeeff"), subtype=8),
            fake_packet(bytes.fromhex("ffffffffffff")),
            fake_packet(bytes.fromhex("a8bbccddeeff"), strength=20),
        )
        for packet in cases:
            with self.subTest(packet=packet):
                self.assertIsNone(
                    record_from_decoded(
                        packet,
                        timestamp="2026-01-01T00:00:00.000001Z",
                        channel=1,
                        sensor_name="A01",
                        pseudonymizer=PSEUDONYMIZER,
                    )
                )

    def test_bad_frame_bytes_are_silently_discarded(self):
        self.assertIsNone(
            parse_frame(
                b"not-a-radiotap-frame",
                timestamp="2026-01-01T00:00:00.000001Z",
                channel=1,
                sensor_name="A01",
                pseudonymizer=PSEUDONYMIZER,
            )
        )
        self.assertIsNone(
            parse_frame(
                bytes.fromhex("65be429c"),
                timestamp="2026-01-01T00:00:00.000001Z",
                channel=1,
                sensor_name="A01",
                pseudonymizer=PSEUDONYMIZER,
            )
        )


if __name__ == "__main__":
    unittest.main()
