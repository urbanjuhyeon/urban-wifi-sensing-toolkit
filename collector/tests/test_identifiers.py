import unittest

from urban_wifi_capture.identifiers import (
    InvalidSourceAddress,
    Pseudonymizer,
    classify_and_pseudonymize_source,
)

TEST_KEY = bytes(range(32))
DEPLOYMENT_ID = "DEPLOYMENT_TEST_2026"


class IdentifierTests(unittest.TestCase):
    def setUp(self):
        self.pseudonymizer = Pseudonymizer(DEPLOYMENT_ID, TEST_KEY)

    def test_fixed_cross_language_vector(self):
        token = classify_and_pseudonymize_source("AA:BB:CC:DD:EE:FF", self.pseudonymizer)
        self.assertEqual(
            token.identifier,
            "e6ef51ca345d85b9eebaf92e2dc5d20e",  # pragma: allowlist secret
        )

    def test_scope_is_stable_within_deployment_and_changes_across_deployments(self):
        first = classify_and_pseudonymize_source("A8:BB:CC:DD:EE:FF", self.pseudonymizer)
        restart = classify_and_pseudonymize_source(
            "A8:BB:CC:DD:EE:FF", Pseudonymizer(DEPLOYMENT_ID, TEST_KEY)
        )
        another_deployment = classify_and_pseudonymize_source(
            "A8:BB:CC:DD:EE:FF", Pseudonymizer("DEPLOYMENT_TEST_2027", TEST_KEY)
        )
        another_key = classify_and_pseudonymize_source(
            "A8:BB:CC:DD:EE:FF", Pseudonymizer(DEPLOYMENT_ID, bytes(reversed(TEST_KEY)))
        )
        self.assertEqual(first, restart)
        self.assertNotEqual(first.identifier, another_deployment.identifier)
        self.assertNotEqual(first.identifier, another_key.identifier)
        self.assertRegex(first.identifier, r"^[0-9a-f]{32}$")

    def test_key_is_not_exposed_by_repr(self):
        rendered = repr(self.pseudonymizer)
        self.assertNotIn(repr(TEST_KEY), rendered)
        self.assertNotIn("key=", rendered)

    def test_randomized_flag_is_read_before_hmac(self):
        local = classify_and_pseudonymize_source("AA:BB:CC:DD:EE:FF", self.pseudonymizer)
        global_address = classify_and_pseudonymize_source("A8:BB:CC:DD:EE:FF", self.pseudonymizer)
        self.assertIsNotNone(local)
        self.assertIsNotNone(global_address)
        self.assertEqual(local.randomized, 1)
        self.assertEqual(global_address.randomized, 0)
        self.assertRegex(local.identifier, r"^[0-9a-f]{32}$")

    def test_bytes_and_text_have_identical_output(self):
        text = classify_and_pseudonymize_source("a8:bb:cc:dd:ee:ff", self.pseudonymizer)
        raw = classify_and_pseudonymize_source(bytes.fromhex("a8bbccddeeff"), self.pseudonymizer)
        self.assertEqual(text, raw)

    def test_invalid_group_sources_are_dropped(self):
        self.assertIsNone(classify_and_pseudonymize_source("00:00:00:00:00:00", self.pseudonymizer))
        self.assertIsNone(classify_and_pseudonymize_source("ff:ff:ff:ff:ff:ff", self.pseudonymizer))
        self.assertIsNone(classify_and_pseudonymize_source("01:00:5e:00:00:01", self.pseudonymizer))

    def test_malformed_sources_raise_without_partial_hmac(self):
        for value in ("aa:bb", b"\xaa\xbb", "not-an-address", [1, 2, 3, 4, 5, 999]):
            with self.subTest(value=value):
                with self.assertRaises(InvalidSourceAddress):
                    classify_and_pseudonymize_source(value, self.pseudonymizer)


if __name__ == "__main__":
    unittest.main()
