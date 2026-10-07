"""The business rules alone (API key, image judgment): no Lambda event. Run: python3 -m unittest -v"""

import hashlib
import unittest

from analyzer import Analysis, ApiKey, NoApiKey, analyze


class Analyze(unittest.TestCase):
    def test_every_image_is_valid_and_fingerprinted(self) -> None:
        image = bytes.fromhex("ffd8ffe000104a464946")
        self.assertEqual(
            analyze(image),
            Analysis(valid=True, reason="stub", size=len(image), sha256=hashlib.sha256(image).hexdigest()),
        )


class ApiKeyRule(unittest.TestCase):
    def test_only_the_same_key_matches(self) -> None:
        key = ApiKey("test-key")
        self.assertTrue(key.matches("test-key"))
        for given in ("", "nope", "test-key-longer", "TEST-KEY"):
            with self.subTest(given=given):
                self.assertFalse(key.matches(given))

    def test_no_api_key_lets_everything_through(self) -> None:
        self.assertTrue(NoApiKey().matches(""))


if __name__ == "__main__":
    unittest.main()
