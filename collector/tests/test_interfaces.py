import unittest
from types import SimpleNamespace
from unittest.mock import call, patch

from urban_wifi_capture.config import InterfaceConfig
from urban_wifi_capture.interfaces import (
    IP_BINARY,
    IW_BINARY,
    NMCLI_BINARY,
    InterfaceError,
    bring_down,
    bring_up,
    capture_interfaces,
    resolve_interfaces,
    status,
)


class AutomaticInterfaceTests(unittest.TestCase):
    def config(self, channels=(1, 6, 11)):
        return SimpleNamespace(interfaces=(), auto_channels=channels)

    def test_excludes_wireless_default_route_and_maps_remaining_adapters(self):
        wireless = {
            "wlan3": "managed",
            "wlan1": "managed",
            "wlan0": "managed",
            "wlan2": "managed",
            "p2p-dev-wlan1": "P2P-device",
        }
        with (
            patch(
                "urban_wifi_capture.interfaces._wireless_interface_types",
                return_value=wireless,
            ),
            patch(
                "urban_wifi_capture.interfaces._default_route_interfaces",
                return_value={"wlan1"},
            ),
        ):
            resolved = resolve_interfaces(self.config())

        self.assertEqual(
            [(item.physical, item.monitor, item.channel) for item in resolved],
            [
                ("wlan0", "ucap0", 1),
                ("wlan2", "ucap1", 6),
                ("wlan3", "ucap2", 11),
            ],
        )

    def test_supports_one_adapter_without_fixed_name_or_mac(self):
        with (
            patch(
                "urban_wifi_capture.interfaces._wireless_interface_types",
                return_value={"wlp-admin": "managed", "wlx-any": "managed"},
            ),
            patch(
                "urban_wifi_capture.interfaces._default_route_interfaces",
                return_value={"wlp-admin"},
            ),
        ):
            resolved = resolve_interfaces(self.config((6,)))
        self.assertEqual(
            [(item.physical, item.monitor, item.channel) for item in resolved],
            [("wlx-any", "ucap0", 6)],
        )

    def test_fails_before_mutation_when_adapter_count_does_not_match(self):
        with (
            patch(
                "urban_wifi_capture.interfaces._wireless_interface_types",
                return_value={"wlan0": "managed", "wlan1": "managed"},
            ),
            patch(
                "urban_wifi_capture.interfaces._default_route_interfaces",
                return_value={"wlan0"},
            ),
        ):
            with self.assertRaisesRegex(InterfaceError, "expected 3 capture adapter"):
                resolve_interfaces(self.config())

    def test_requires_exactly_one_wireless_default_route(self):
        with (
            patch(
                "urban_wifi_capture.interfaces._wireless_interface_types",
                return_value={"wlan0": "managed", "wlan1": "managed"},
            ),
            patch(
                "urban_wifi_capture.interfaces._default_route_interfaces",
                return_value={"eth0"},
            ),
        ):
            with self.assertRaisesRegex(InterfaceError, "exactly one"):
                resolve_interfaces(self.config((6,)))

    def test_capture_uses_deterministic_logical_monitor_names(self):
        resolved = capture_interfaces(self.config((1, 11)))
        self.assertEqual(
            [(item.physical, item.monitor, item.channel) for item in resolved],
            [("auto0", "ucap0", 1), ("auto1", "ucap1", 11)],
        )

    def test_monitor_creation_temporarily_releases_network_manager(self):
        item = InterfaceConfig(physical="wlan0", monitor="ucap0", channel=6)
        with (
            patch("urban_wifi_capture.interfaces._exists", side_effect=(True, False)),
            patch("urban_wifi_capture.interfaces.Path.exists", return_value=True),
            patch("urban_wifi_capture.interfaces.time.sleep"),
            patch("urban_wifi_capture.interfaces._run") as run,
        ):
            bring_up(item)
        self.assertEqual(
            run.call_args_list,
            [
                call([NMCLI_BINARY, "device", "set", "wlan0", "managed", "no"]),
                call([IP_BINARY, "link", "set", "wlan0", "down"]),
                call(
                    [
                        IW_BINARY,
                        "dev",
                        "wlan0",
                        "interface",
                        "add",
                        "ucap0",
                        "type",
                        "monitor",
                    ]
                ),
                call([IP_BINARY, "link", "set", "ucap0", "up"]),
                call([IW_BINARY, "dev", "ucap0", "set", "channel", "6"]),
            ],
        )

    def test_monitor_removal_returns_adapter_to_network_manager(self):
        item = InterfaceConfig(physical="wlan0", monitor="ucap0", channel=6)
        with (
            patch("urban_wifi_capture.interfaces._exists", return_value=True),
            patch("urban_wifi_capture.interfaces.Path.exists", return_value=True),
            patch("urban_wifi_capture.interfaces._run") as run,
        ):
            bring_down(item)
        self.assertEqual(
            run.call_args_list,
            [
                call([IW_BINARY, "dev", "ucap0", "del"]),
                call([IP_BINARY, "link", "set", "wlan0", "up"]),
                call([NMCLI_BINARY, "device", "set", "wlan0", "managed", "yes"]),
            ],
        )

    def test_status_reports_virtual_monitor_presence(self):
        items = (
            InterfaceConfig(physical="wlan0", monitor="ucap0", channel=1),
            InterfaceConfig(physical="wlan2", monitor="ucap1", channel=6),
        )
        with patch("urban_wifi_capture.interfaces._exists", side_effect=(True, False)):
            lines = status(items)
        self.assertEqual(
            lines,
            [
                "ucap0: present (physical=wlan0, channel=1)",
                "ucap1: missing (physical=wlan2, channel=6)",
            ],
        )


if __name__ == "__main__":
    unittest.main()
