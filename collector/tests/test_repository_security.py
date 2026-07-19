import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class RepositorySecurityTests(unittest.TestCase):
    def test_runtime_version_matches_package_metadata(self):
        pyproject = (ROOT / "pyproject.toml").read_text(encoding="utf-8")
        package_init = (ROOT / "src" / "urban_wifi_capture" / "__init__.py").read_text(
            encoding="utf-8"
        )
        project_version = re.search(r'^version = "([^"]+)"$', pyproject, re.MULTILINE)
        runtime_version = re.search(r'^__version__ = "([^"]+)"$', package_init, re.MULTILINE)
        self.assertIsNotNone(project_version)
        self.assertIsNotNone(runtime_version)
        self.assertEqual(project_version.group(1), runtime_version.group(1))

    def test_readme_does_not_recommend_root_capture(self):
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        forbidden = "sudo /opt/urban-sensing/venv/bin/" + "urban-wifi-capture capture"
        self.assertNotIn(forbidden, readme)
        self.assertIn("Never run the `capture` subcommand directly with `sudo`", readme)

    def test_capture_service_is_unprivileged_and_bounded(self):
        service = (ROOT / "systemd" / "urban-wifi-capture.service").read_text(encoding="utf-8")
        self.assertIn("User=urban-sensing", service)
        self.assertIn("UMask=0077", service)
        self.assertIn("CapabilityBoundingSet=CAP_NET_RAW", service)  # pragma: allowlist secret
        self.assertIn("NoNewPrivileges=true", service)
        self.assertIn("ReadOnlyPaths=/etc/urban-sensing", service)
        self.assertIn("KillMode=mixed", service)
        self.assertIn("TimeoutStopSec=120", service)
        self.assertIn("StartLimitIntervalSec=300", service)
        self.assertIn("StartLimitBurst=3", service)
        self.assertIn("LimitCORE=0", service)
        self.assertNotIn("User=root", service)
        self.assertNotIn("CAP_NET_ADMIN", service)

    def test_interface_service_is_bounded_root_oneshot_for_network_manager(self):
        service = (ROOT / "systemd" / "urban-wifi-interfaces.service").read_text(encoding="utf-8")
        self.assertNotIn("User=", service)
        self.assertIn("SupplementaryGroups=urban-sensing", service)
        self.assertIn("CapabilityBoundingSet=CAP_NET_ADMIN", service)  # pragma: allowlist secret
        self.assertIn("RestrictAddressFamilies=AF_UNIX AF_NETLINK", service)
        self.assertIn("After=network-online.target", service)
        self.assertIn("NetworkManager.service", service)
        self.assertIn("ReadOnlyPaths=/etc/urban-sensing", service)
        self.assertIn("LimitCORE=0", service)
        self.assertIn("Type=oneshot", service)

    def test_runtime_files_have_no_world_writable_or_home_pi_contract(self):
        roots = [ROOT / "src", ROOT / "code", ROOT / "scripts", ROOT / "systemd"]
        content = "\n".join(
            path.read_text(encoding="utf-8", errors="replace")
            for root in roots
            for path in root.rglob("*")
            if path.is_file()
        ).lower()
        self.assertNotIn("chmod 777", content)
        self.assertNotIn("chmod 0777", content)
        self.assertNotIn("/home/pi", content)
        self.assertNotIn("dropbox", content)
        self.assertNotIn("bluelog", content)
        self.assertNotIn("hexlify", content)

    def test_installer_repairs_staged_venv_for_runtime_use(self):
        installer = (ROOT / "scripts" / "install.sh").read_text(encoding="utf-8")
        first_cleanup = installer.index("clean_local_build_artifacts")
        package_install = installer.index('--no-build-isolation "${REPOSITORY_ROOT}"')
        self.assertLess(first_cleanup, package_install)
        self.assertIn('"${REPOSITORY_ROOT}/build"', installer)
        self.assertIn('"${REPOSITORY_ROOT}/src/"*.egg-info', installer)
        self.assertIn('"#!${VENV_STAGE}/bin/python"*', installer)
        self.assertIn('sed -i "1c\\\\#!${VENV}/bin/python"', installer)
        self.assertIn('chmod -R a+rX,go-w "${INSTALL_ROOT}"', installer)

    def test_obsolete_capture_scripts_are_absent(self):
        for name in (
            "envr.sh",
            "name.sh",
            "packages.sh",
            "service.sh",
            "sensor_name.conf",
        ):
            self.assertFalse((ROOT / name).exists(), name)

    def test_no_deployment_secret_file_is_present_in_repository(self):
        forbidden_suffixes = {".key", ".secret", ".pem"}
        found = [
            path.relative_to(ROOT).as_posix()
            for path in ROOT.rglob("*")
            if path.is_file()
            and ".git" not in path.parts
            and not set(path.relative_to(ROOT).parts)
            & {".venv", ".venv-test", "build", "dist", "__pycache__"}
            and path.suffix.lower() in forbidden_suffixes
        ]
        self.assertEqual(found, [])

    def test_example_configuration_references_a_file_but_contains_no_key(self):
        content = (ROOT / "config.example.json").read_text(encoding="utf-8")
        self.assertIn('"pseudonymization_key_file"', content)
        self.assertNotIn('"pseudonymization_key"', content)


if __name__ == "__main__":
    unittest.main()
