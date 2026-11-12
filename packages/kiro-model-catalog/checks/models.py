"""Exercise model-table normalization and refusal with minimal Markdown rows."""

import importlib.util
import sys
import unittest

spec = importlib.util.spec_from_file_location("kiro_models", sys.argv.pop(1))
models = importlib.util.module_from_spec(spec)
spec.loader.exec_module(models)
TABLE = "## Quick comparison\n| Model | Context |\n| --- | --- |\n| Auto | 1M |\n"


class ModelExtraction(unittest.TestCase):
    def test_normalization(self):
        for wrong, row, expected in (
            ("spaces left intact", "**Claude Sonnet 5**", "claude-sonnet-5"),
            ("decimal truncated", "Claude Sonnet 4.0", "claude-sonnet-4.0"),
            ("provider allowlist", "Nova 2", "nova-2"),
        ):
            with self.subTest(wrong_implementation=wrong):
                self.assertEqual(models.model_ids(models.capture(
                    TABLE + f"| {row} | 1M |\n"
                )), ["auto", expected])

    def test_refuse_malformed_row_instead_of_silently_dropping_it(self):
        with self.assertRaisesRegex(ValueError, "malformed model table row"):
            models.capture(TABLE + "| Nova 2 |\n")


unittest.main()
