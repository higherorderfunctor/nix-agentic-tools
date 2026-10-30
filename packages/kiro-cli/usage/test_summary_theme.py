"""Exit-summary theme: style grammar, color resolution, alignment and borders over synthetic reports."""

import io
import json
import re
import tempfile
import unittest

import query
import summary_theme
import test_query


SGR = re.compile(r"\x1b\[[0-9;]*m")


class Terminal(io.StringIO):
    def isatty(self):
        return True


def load(theme, stream=None, environ=None):
    with tempfile.NamedTemporaryFile("w", suffix=".json") as file:
        json.dump(theme, file)
        file.flush()
        return summary_theme.load(file.name, stream or Terminal(), {} if environ is None else environ)


class ThemeTests(unittest.TestCase):
    def setUp(self):
        fixture = test_query.QueryTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        for ident, conversation, credits in (("a", "root", 1), ("b", "child", None)):
            fixture.captured(ident, conversation=conversation, credits=credits, metadata={"kiro:root_conversation_id": "root"})
        self.report = query.query(fixture.db, "sess_root", "tree")
        self.plain = query.render_summary(self.report)

    def test_style_specs_parse_attributes_palette_and_rgb(self):
        self.assertEqual(summary_theme.sgr("bold bright-red on-blue #ff8800 on-#00ff7F"),
                         "\x1b[1;91;44;38;2;255;136;0;48;2;0;255;127m")
        self.assertEqual(summary_theme.sgr(""), "")
        for token in ("blink", "on-bold", "#fff", "bright-bright-red", "on-"):
            with self.assertRaisesRegex(ValueError, re.escape(repr(token))):
                summary_theme.sgr("bold " + token)
        with self.assertRaisesRegex(ValueError, "'blink'"):
            load({"styles": {"header": "blink"}, "color": "never"})
        for refused in ({"colour": "never"}, {"border": "dashed"}, {"color": "sometimes"}, {"icons": "yes"}, {"styles": {"footer": "bold"}}, []):
            with self.assertRaises(ValueError):
                load(refused)

    def test_auto_color_needs_a_terminal_and_no_no_color(self):
        self.assertTrue(load({})["styles"])
        self.assertFalse(load({}, io.StringIO())["styles"])
        self.assertFalse(load({}, environ={"NO_COLOR": "1"})["styles"])
        self.assertTrue(load({}, environ={"NO_COLOR": ""})["styles"])
        self.assertFalse(load({"color": "never"})["styles"])
        self.assertTrue(load({"color": "always"}, io.StringIO(), {"NO_COLOR": "1"})["styles"])

    def test_no_theme_file_stays_plain_on_a_terminal(self):
        self.assertEqual(summary_theme.load(None, Terminal(), {}), summary_theme.PLAIN)

    def test_unhashable_enum_values_are_refused(self):
        for theme in ({"border": []}, {"color": {}}):
            with self.assertRaises(ValueError):
                load(theme)

    def test_default_theme_output_is_unchanged(self):
        for theme in ({}, {"color": "never", "border": "none", "icons": False}):
            self.assertEqual(query.render_summary(self.report, (), load(theme, io.StringIO())), self.plain)
        self.assertNotIn("\x1b", self.plain)

    def test_styles_keep_alignment(self):
        styled = query.render_summary(self.report, (), load({"color": "always", "styles": {"label": "italic #102030", "number": "cyan"}}))
        self.assertIn("\x1b[1m\x1b[3;38;2;16;32;48mTotal\x1b[0m", styled)  # total, then the label column's own style
        self.assertIn("\x1b[3;38;2;16;32;48mMain\x1b[0m", styled)
        self.assertIn("\x1b[2m—\x1b[0m", styled)
        self.assertIn("\x1b[33m⚠ credits unknown", styled)
        self.assertEqual(SGR.sub("", styled), self.plain)

    def test_each_border_closes_one_box_and_turns_the_rule_into_a_junction(self):
        rule = next(index for index, line in enumerate(self.plain.splitlines()) if set(line) == {"-"})
        for name, (corner, horizontal, corner_right, vertical, tee, tee_right, bottom, bottom_right) in summary_theme.BORDERS.items():
            for color in ("never", "always"):
                lines = SGR.sub("", query.render_summary(self.report, (), load({"border": name, "color": color, "icons": True}))).splitlines()
                self.assertEqual(len({len(line) for line in lines}), 1, name)
                self.assertEqual((lines[0][0], lines[0][-1], lines[-1][0], lines[-1][-1]), (corner, corner_right, bottom, bottom_right))
                self.assertEqual({line[0] + line[-1] for line in lines[1:-1]}, {vertical * 2, tee + tee_right})
                self.assertEqual([line for line in lines[1:-1] if line[0] == tee], [tee + horizontal * (len(lines[0]) - 2) + tee_right])
                self.assertEqual(lines[rule + 1][0], tee)  # the plain dash rule, one line down below the top edge
                self.assertTrue(lines[1].startswith(vertical + " \uf080 Kiro usage"))
                self.assertTrue(lines[-2].startswith(vertical + " \uf071 credits unknown"))


if __name__ == "__main__":
    unittest.main()
