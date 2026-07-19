import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from urban_wifi_capture.cli import build_parser, main


class CliTests(unittest.TestCase):
    def _config_path(self, directory):
        key = Path(directory) / "deployment.key"
        key.write_bytes(bytes(range(32)))
        if os.name == "posix":
            key.chmod(0o600)
        path = Path(directory) / "config.json"
        path.write_text(
            json.dumps(
                {
                    "sensor_name": "A01",
                    "deployment_id": "FIELDWORK_2026_01",
                    "pseudonymization_key_file": "deployment.key",
                    "data_dir": "/var/lib/urban-sensing/data",
                    "interfaces": [{"physical": "wlan1", "monitor": "wlan1mon", "channel": 1}],
                }
            ),
            encoding="utf-8",
        )
        return path

    def test_self_test(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(main(["self-test"]), 0)
        self.assertIn("PASS", output.getvalue())

    def test_raw_packet_options_do_not_exist(self):
        parser = build_parser()
        for option in (
            "-i",
            "--info",
            "--raw",
            "-b",
            "--bluetooth",
            "--ssid",
            "--bssid",
            "--destination-address",
            "--dropbox",
        ):
            with self.subTest(option=option), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    parser.parse_args(["capture", "--config", "config.json", option])
                self.assertEqual(raised.exception.code, 2)

    def test_secret_key_cannot_be_supplied_as_a_cli_value(self):
        parser = build_parser()
        for option in ("--key", "--pseudonymization-key", "--deployment-key"):
            with self.subTest(option=option), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    parser.parse_args(["capture", "--config", "config.json", option, "secret"])
                self.assertEqual(raised.exception.code, 2)

    def test_generate_key_prints_only_the_path_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "deployment.key"
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(main(["generate-key", "--output", str(path)]), 0)
            payload = path.read_bytes()
            self.assertEqual(len(payload), 32)
            self.assertNotIn(payload.hex(), output.getvalue())
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
                main(["generate-key", "--output", str(path)])
            self.assertEqual(raised.exception.code, 1)
            self.assertEqual(path.read_bytes(), payload)

    def test_validate_checks_production_data_directory(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch("urban_wifi_capture.cli.validate_runtime_data_dir") as validate,
        ):
            path = self._config_path(directory)
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(["validate", "--config", str(path)]), 0)
            validate.assert_called_once()

    def test_runtime_permission_error_is_concise(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch(
                "urban_wifi_capture.cli.validate_runtime_data_dir",
                side_effect=PermissionError("unsafe runtime data directory"),
            ),
        ):
            path = self._config_path(directory)
            error = io.StringIO()
            with contextlib.redirect_stderr(error), self.assertRaises(SystemExit) as raised:
                main(["validate", "--config", str(path)])
            self.assertEqual(raised.exception.code, 1)
            self.assertIn("error: unsafe runtime data directory", error.getvalue())
            self.assertNotIn("Traceback", error.getvalue())

    def test_interface_teardown_remains_available_if_key_is_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self._config_path(directory)
            (Path(directory) / "deployment.key").unlink()
            with patch("urban_wifi_capture.cli.bring_all_down") as bring_down:
                self.assertEqual(
                    main(["interfaces", "down", "--config", str(path)]),
                    0,
                )
            bring_down.assert_called_once()

    def test_interface_setup_fails_closed_if_key_is_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self._config_path(directory)
            (Path(directory) / "deployment.key").unlink()
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
                main(["interfaces", "up", "--config", str(path)])
            self.assertEqual(raised.exception.code, 1)

    def test_interface_plan_is_read_only_and_does_not_require_key(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self._config_path(directory)
            (Path(directory) / "deployment.key").unlink()
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(
                    main(["interfaces", "plan", "--config", str(path)]),
                    0,
                )
            self.assertEqual(
                output.getvalue().strip(),
                "wlan1mon: planned (physical=wlan1, channel=1)",
            )


if __name__ == "__main__":
    unittest.main()
