"""Exercise the public catalog parser, including both observed account catalogs."""

import importlib.util
import json
import sys
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("kiro_models", sys.argv.pop(1))
models = importlib.util.module_from_spec(spec)
spec.loader.exec_module(models)
snapshot = Path(sys.argv.pop(1))


def document(*names):
    return (
        "# Models\n\n## Quick comparison\n\n"
        "| Model | Context |\n| --- | --- |\n"
        + "".join(f"| {name} | 1M |\n" for name in names)
        + "\n## Other section\n| unrelated | row |\n"
    )


class ModelExtraction(unittest.TestCase):
    def test_current_snapshot_covers_both_observed_accounts(self):
        # Kiro 2.22.1, 2026-09-19: work account + isolated free account.
        observed = set("""
            auto claude-haiku-4.5 claude-opus-4.5 claude-opus-4.6
            claude-opus-4.7 claude-opus-4.8 claude-opus-5 claude-sonnet-4
            claude-sonnet-4.5 claude-sonnet-4.6 claude-sonnet-5 deepseek-3.2
            glm-5 gpt-5.6-luna gpt-5.6-sol gpt-5.6-terra minimax-m2.1
            minimax-m2.5 qwen3-coder-next
        """.split())
        extracted = set(models.model_ids(json.loads(snapshot.read_text())))
        self.assertEqual(observed - extracted, set())

    def test_table_boundaries_annotations_and_new_versions(self):
        captured = models.capture(document(
            "**Auto**", "**Claude Sonnet 4.0**",
            "**Claude Opus 99.1**<sup>†</sup>", "GPT-99.1 Luna",
        ))
        self.assertEqual(models.model_ids(captured), [
            "auto", "claude-opus-99.1", "claude-sonnet-4", "gpt-99.1-luna",
        ])

    def test_recipe_id_supplements_display_inference(self):
        for names in (("Auto", "Claude Fable 5.1"),
                      ("Auto", "Claude Fable 5", "Claude Fable 5.1")):
            with self.subTest(names=names):
                self.assertEqual(models.model_ids(models.capture(document(*names))), [
                    "auto", "claude-fable-5", "claude-fable-5.1",
                ])
        current = models.model_ids(json.loads(snapshot.read_text()))
        self.assertIn("claude-fable-5", current)
        self.assertIn("claude-fable-5.1", current)

    def test_missing_ambiguous_and_degraded_tables_fail(self):
        for source in ("", "<html>login</html>", document("Auto"),
                       document("Auto", "Claude Opus 5") * 2):
            with self.subTest(source=source), self.assertRaises(ValueError):
                models.capture(source)

    def test_unknown_rows_fail_instead_of_disappearing(self):
        for name in ("New Provider 9", "", "**Claude Opus 5** (retired)"):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "unrecognized"):
                models.capture(document("Auto", name))

    def test_malformed_row_fails(self):
        source = document("Auto", "Claude Opus 5").replace(
            "| Claude Opus 5 | 1M |", "| Claude Opus 5 |"
        )
        with self.assertRaisesRegex(ValueError, "malformed"):
            models.capture(source)

    def test_interrupted_table_does_not_publish_a_prefix(self):
        source = document("Auto", "Claude Opus 5", "GPT-5.6 Sol").replace(
            "| GPT-5.6 Sol", "\n| GPT-5.6 Sol"
        )
        with self.assertRaisesRegex(ValueError, "interrupted"):
            models.capture(source)

    def test_duplicate_and_colliding_names_fail(self):
        for names in (("Auto", "Auto"), ("Auto", "Claude Sonnet 4", "Claude Sonnet 4.0")):
            with self.subTest(names=names), self.assertRaisesRegex(ValueError, "colliding"):
                models.capture(document(*names))

    def test_invalid_snapshot_shape_fails(self):
        for catalog in (None, [], {}, {"source": models.SOURCE, "models": [None]}):
            with self.subTest(catalog=catalog), self.assertRaises(ValueError):
                models.model_ids(catalog)


unittest.main()
