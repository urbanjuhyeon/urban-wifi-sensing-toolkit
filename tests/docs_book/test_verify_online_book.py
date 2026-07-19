from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DOCS_ROOT = REPOSITORY_ROOT / "docs"
DOC_VERIFIER_DIR = REPOSITORY_ROOT / "scripts" / "docs"
sys.path.insert(0, str(DOC_VERIFIER_DIR))

import verify_online_book as verifier  # noqa: E402


RESOURCE_LINKS = "\n".join(
    f'<a href="{relative.as_posix()}">{relative.name}</a>'
    for relative in verifier.REQUIRED_RESOURCES
)


class OnlineBookVerifierTest(unittest.TestCase):
    def make_book(
        self,
        parent: Path,
        *,
        extra_html: str = "",
        linked_resources: tuple[Path, ...] = verifier.REQUIRED_RESOURCES,
    ) -> Path:
        root = parent / "rendered-book"
        downloads = root / "downloads"
        downloads.mkdir(parents=True)
        for relative in verifier.REQUIRED_RESOURCES:
            source = DOCS_ROOT / relative
            self.assertTrue(source.is_file(), source)
            shutil.copy2(source, root / relative)
        links = "\n".join(
            f'<a href="{relative.as_posix()}">{relative.name}</a>'
            for relative in linked_resources
        )
        (root / "index.html").write_text(
            "<!doctype html><html><head><meta charset=\"utf-8\"></head>"
            f"<body>{links}{extra_html}</body></html>\n",
            encoding="utf-8",
            newline="\n",
        )
        return root

    def test_neutral_fixture_passes_public_and_anonymous_modes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self.make_book(Path(temporary))
            public = verifier.verify_online_book(
                root, mode="public", repository_root=REPOSITORY_ROOT
            )
            anonymous = verifier.verify_online_book(
                root, mode="anonymous", repository_root=REPOSITORY_ROOT
            )
            self.assertEqual(public.html_files, 1)
            self.assertEqual(anonymous.capture_sha256, public.capture_sha256)
            self.assertEqual(anonymous.synthetic_sha256, public.synthetic_sha256)

    def test_anonymous_mode_rejects_author_identity_but_public_mode_allows_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self.make_book(
                Path(temporary), extra_html="<p>Juhyeon Park</p>"
            )
            verifier.verify_online_book(
                root, mode="public", repository_root=REPOSITORY_ROOT
            )
            with self.assertRaisesRegex(
                verifier.OnlineBookValidationError, "author-identifying"
            ):
                verifier.verify_online_book(
                    root, mode="anonymous", repository_root=REPOSITORY_ROOT
                )

    def test_missing_traversal_and_absolute_local_links_fail_closed(self) -> None:
        cases = (
            ("missing.png", "missing local"),
            ("../outside.png", "traversal"),
            ("/absolute.png", "absolute local"),
            (r"C:\\Users\\person\\file.png", "absolute local"),
            ("%2e%2e/outside.png", "traversal"),
            ("http://[", "malformed"),
        )
        for href, message in cases:
            with self.subTest(href=href), tempfile.TemporaryDirectory() as temporary:
                root = self.make_book(
                    Path(temporary), extra_html=f'<img src="{href}">'
                )
                with self.assertRaisesRegex(
                    verifier.OnlineBookValidationError, message
                ):
                    verifier.verify_online_book(
                        root, mode="public", repository_root=REPOSITORY_ROOT
                    )

    def test_legacy_hash_raw_mac_and_secret_material_are_rejected(self) -> None:
        findings = (
            (
                "Use SHA-256 truncated to the first 16 hexadecimal characters.",
                "active SHA16",
            ),
            ("aa:bb:cc:dd:ee:ff", "raw MAC-like"),
            ("AKIA1234567890ABCDEF", "AWS access token"),
        )
        for content, message in findings:
            with self.subTest(message=message), tempfile.TemporaryDirectory() as temporary:
                root = self.make_book(
                    Path(temporary), extra_html=f"<pre>{content}</pre>"
                )
                with self.assertRaisesRegex(
                    verifier.OnlineBookValidationError, message
                ):
                    verifier.verify_online_book(
                        root, mode="public", repository_root=REPOSITORY_ROOT
                    )

    def test_historical_context_does_not_trigger_active_legacy_rule(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self.make_book(
                Path(temporary),
                extra_html=(
                    "<p>The retired historical format truncated SHA-256 to the "
                    "first 16 hexadecimal characters; never use it for new capture.</p>"
                ),
            )
            verifier.verify_online_book(
                root, mode="public", repository_root=REPOSITORY_ROOT
            )

    def test_every_required_resource_must_exist_and_be_linked(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self.make_book(
                Path(temporary),
                linked_resources=verifier.REQUIRED_RESOURCES[:-1],
            )
            with self.assertRaisesRegex(
                verifier.OnlineBookValidationError, "not linked"
            ):
                verifier.verify_online_book(
                    root, mode="public", repository_root=REPOSITORY_ROOT
                )
        with tempfile.TemporaryDirectory() as temporary:
            root = self.make_book(Path(temporary))
            (root / verifier.CAPTURE_CHECKSUM).unlink()
            with self.assertRaisesRegex(
                verifier.OnlineBookValidationError, "missing local|required"
            ):
                verifier.verify_online_book(
                    root, mode="public", repository_root=REPOSITORY_ROOT
                )

    def test_current_capture_and_synthetic_downloads_verify(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self.make_book(Path(temporary))
            capture, synthetic = verifier.verify_required_archives(
                root, REPOSITORY_ROOT
            )
            self.assertEqual(len(capture), 64)
            self.assertEqual(len(synthetic), 64)

    def test_synthetic_test_key_exception_is_confined_to_fixture_manifest(self) -> None:
        module = verifier._load_synthetic_verifier(REPOSITORY_ROOT)
        payload = module.verify_archive(DOCS_ROOT / verifier.SYNTHETIC_ARCHIVE)
        verifier._scan_archive_payload(
            payload,
            synthetic_test_key=module.PUBLIC_TEST_KEY,
            synthetic_key_member=module.FIXTURE_MANIFEST,
        )
        widened = dict(payload)
        widened["README.md"] += module.PUBLIC_TEST_KEY
        with self.assertRaisesRegex(
            verifier.OnlineBookValidationError, "outside its fixture manifest"
        ):
            verifier._scan_archive_payload(
                widened,
                synthetic_test_key=module.PUBLIC_TEST_KEY,
                synthetic_key_member=module.FIXTURE_MANIFEST,
            )

    def test_capture_internal_manifest_detects_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original = DOCS_ROOT / verifier.CAPTURE_ARCHIVE
            tampered = root / verifier.CAPTURE_ARCHIVE.name
            with zipfile.ZipFile(original, "r") as source, zipfile.ZipFile(
                tampered, "w"
            ) as output:
                for info in source.infolist():
                    data = source.read(info)
                    if info.filename == "capture-scripts/README.md":
                        data += b"tampered\n"
                    output.writestr(info, data)
            checksum = root / verifier.CAPTURE_CHECKSUM.name
            checksum.write_text(
                f"{verifier.sha256_file(tampered)}  {tampered.name}\n",
                encoding="ascii",
                newline="\n",
            )
            with self.assertRaisesRegex(
                verifier.OnlineBookValidationError, "manifest hash"
            ):
                verifier._verify_capture_archive(tampered, checksum)

    def test_git_metadata_and_key_files_are_forbidden_archive_entries(self) -> None:
        for name in (".git/config", "private/deployment.key"):
            with self.subTest(name=name), self.assertRaises(
                verifier.OnlineBookValidationError
            ):
                verifier._safe_member_name(name)


class AnonymousProfileTest(unittest.TestCase):
    def test_quarto_inspect_has_anonymous_output_and_blank_identity_metadata(self) -> None:
        quarto = shutil.which("quarto")
        if quarto is None:
            self.skipTest("Quarto is unavailable")
        completed = subprocess.run(
            [quarto, "inspect", str(DOCS_ROOT), "--profile", "anonymous"],
            cwd=REPOSITORY_ROOT,
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        inspection = json.loads(completed.stdout)
        config = inspection["config"]
        self.assertEqual(config["project"]["output-dir"], "_book-anon")
        self.assertIn(config["book"].get("author"), (None, "", []))
        self.assertEqual(config["book"].get("site-url", ""), "")
        self.assertEqual(config["book"].get("repo-url", ""), "")
        resources = set(config["project"]["resources"])
        self.assertTrue(
            {relative.as_posix() for relative in verifier.REQUIRED_RESOURCES}
            <= resources
        )

    def test_profile_render_omits_author_site_and_repository_metadata(self) -> None:
        quarto = shutil.which("quarto")
        if quarto is None:
            self.skipTest("Quarto is unavailable")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copy2(
                DOCS_ROOT / "_quarto-anonymous.yml",
                root / "_quarto-anonymous.yml",
            )
            (root / "_quarto.yml").write_text(
                "project:\n"
                "  type: book\n"
                "book:\n"
                "  title: Profile fixture\n"
                "  author: Juhyeon Park\n"
                "  site-url: https://urbanjuhyeon.github.io/example/\n"
                "  repo-url: https://github.com/urbanjuhyeon/example/\n"
                "  chapters: [index.qmd]\n",
                encoding="utf-8",
                newline="\n",
            )
            (root / "index.qmd").write_text(
                "# Neutral fixture\n\nProfile merge test.\n",
                encoding="utf-8",
                newline="\n",
            )
            for relative in verifier.REQUIRED_RESOURCES:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"fixture")
            completed = subprocess.run(
                [quarto, "render", "--profile", "anonymous"],
                cwd=root,
                check=False,
                capture_output=True,
                text=True,
                encoding="utf-8",
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            html = (root / "_book-anon" / "index.html").read_text(
                encoding="utf-8"
            )
            lowered = html.lower()
            self.assertNotIn("juhyeon park", lowered)
            self.assertNotIn("urbanjuhyeon", lowered)
            self.assertNotRegex(lowered, r'<meta[^>]+name=["\']author["\']')
            self.assertNotRegex(lowered, r'<link[^>]+rel=["\']canonical["\']')


if __name__ == "__main__":
    unittest.main()
