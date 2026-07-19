import json
import os
import tempfile
import unittest
from pathlib import Path

from urban_wifi_capture.config import ConfigurationError, load_config, public_summary


def valid_config():
    return {
        "sensor_name": "A01",
        "deployment_id": "FIELDWORK_2026_01",
        "pseudonymization_key_file": "deployment.key",
        "data_dir": "data",
        "queue_size": 1000,
        "batch_size": 100,
        "interfaces": [
            {"physical": "wlan1", "monitor": "wlan1mon", "channel": 1},
            {"physical": "wlan2", "monitor": "wlan2mon", "channel": 6},
        ],
    }


class ConfigTests(unittest.TestCase):
    def write_config(self, directory, content):
        key_path = Path(directory) / "deployment.key"
        if not key_path.exists():
            key_path.write_bytes(bytes(range(32)))
            if os.name == "posix":
                key_path.chmod(0o600)
        path = Path(directory) / "config.json"
        path.write_text(json.dumps(content), encoding="utf-8")
        return path

    def test_loads_relative_data_directory_against_config_location(self):
        with tempfile.TemporaryDirectory() as directory:
            config = load_config(self.write_config(directory, valid_config()))
            self.assertEqual(config.data_dir, (Path(directory) / "data").resolve())
            self.assertEqual(
                config.pseudonymization_key_file,
                (Path(directory) / "deployment.key").resolve(),
            )
            self.assertEqual(config.deployment_id, "FIELDWORK_2026_01")
            self.assertNotIn(repr(bytes(range(32))), repr(config))
            summary = public_summary(config)
            self.assertEqual(summary["identifier_scope"], "deployment")
            self.assertNotIn("pseudonymization_key_file", summary)
            self.assertNotIn("pseudonymization_key", summary)
            for key in (
                "raw_frames_stored",
                "raw_addresses_stored",
                "ssid_stored",
                "bssid_stored",
                "destination_address_stored",
                "bluetooth_stored",
                "cloud_upload_enabled",
            ):
                with self.subTest(key=key):
                    self.assertFalse(summary[key])
            self.assertFalse(summary["raw_addresses_stored"])
            self.assertFalse(summary["ssid_stored"])

    def test_loads_automatic_interface_selection(self):
        content = valid_config()
        content["interfaces"] = {"mode": "auto", "channels": [1, 6, 11]}
        with tempfile.TemporaryDirectory() as directory:
            config = load_config(self.write_config(directory, content))
            self.assertEqual(config.interfaces, ())
            self.assertEqual(config.auto_channels, (1, 6, 11))
            self.assertEqual(public_summary(config)["interfaces"]["mode"], "auto")

    def test_rejects_invalid_automatic_interface_selection(self):
        cases = [
            {"mode": "auto", "channels": []},
            {"mode": "manual", "channels": [1]},
            {"mode": "auto", "channels": [1, 1]},
            {"mode": "auto", "channels": [0]},
            {"mode": "auto", "channels": [True]},
            {"mode": "auto", "channels": ["6"]},
            {"mode": "auto", "channels": [6], "physical": "wlan1"},
        ]
        for interfaces in cases:
            content = valid_config()
            content["interfaces"] = interfaces
            with self.subTest(interfaces=interfaces), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(ConfigurationError):
                    load_config(self.write_config(directory, content))

    def test_rejects_unknown_key(self):
        content = valid_config()
        content["cloud_token"] = "must-not-be-accepted"
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ConfigurationError):
                load_config(self.write_config(directory, content))

    def test_rejects_unsafe_sensor_name(self):
        for value in ("", "sensor name", "A01;touch_x", "A" * 33, "CHANGE_ME"):
            content = valid_config()
            content["sensor_name"] = value
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(ConfigurationError):
                    load_config(self.write_config(directory, content))

    def test_requires_safe_nonplaceholder_deployment_fields(self):
        cases = []
        for key in ("deployment_id", "pseudonymization_key_file"):
            content = valid_config()
            del content[key]
            cases.append(content)
        for value in ("", "site name", "CHANGE_ME_DEPLOYMENT", "A" * 65, None):
            content = valid_config()
            content["deployment_id"] = value
            cases.append(content)
        content = valid_config()
        content["pseudonymization_key_file"] = 123
        cases.append(content)
        for content in cases:
            with self.subTest(content=content), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises((ConfigurationError, PermissionError)):
                    load_config(self.write_config(directory, content))

    def test_rejects_duplicate_interfaces_and_invalid_channels(self):
        content = valid_config()
        content["interfaces"][1]["monitor"] = "wlan1mon"
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ConfigurationError):
                load_config(self.write_config(directory, content))

    def test_rejects_coerced_types_and_ambiguous_interface_names(self):
        cases = []
        for key, value in (("queue_size", True), ("batch_size", 1.5), ("sensor_name", None)):
            content = valid_config()
            content[key] = value
            cases.append(content)
        for key, value in (("physical", "--help"), ("monitor", ".."), ("channel", 1.9)):
            content = valid_config()
            content["interfaces"][0][key] = value
            cases.append(content)
        content = valid_config()
        content["interfaces"][1]["physical"] = "wlan1mon"
        cases.append(content)

        for content in cases:
            with self.subTest(content=content), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(ConfigurationError):
                    load_config(self.write_config(directory, content))

    def test_rejects_duplicate_json_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(
                '{"sensor_name":"A01","sensor_name":"A02","data_dir":"data",'
                '"interfaces":[{"physical":"wlan1","monitor":"wlan1mon","channel":1}]}',
                encoding="utf-8",
            )
            with self.assertRaises(ConfigurationError):
                load_config(path)

        content = valid_config()
        content["interfaces"][0]["channel"] = 36
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ConfigurationError):
                load_config(self.write_config(directory, content))


if __name__ == "__main__":
    unittest.main()
