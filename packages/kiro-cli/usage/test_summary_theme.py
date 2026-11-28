"""Exit-summary theme: style grammar, color resolution, alignment and borders over synthetic reports."""

import io
import json
import re
import tempfile
import unittest
from unittest.mock import patch

import query
import report
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
        self.assertEqual(load({"styles": {"header": ""}})["styles"]["header"], "")  # clear the default bold style

    def test_invalid_theme_names_the_rejected_setting(self):
        cases = (
            ("background attribute", {"styles": {"header": "bold on-bold"}}, "unknown summary style token 'on-bold'"),
            ("empty background", {"styles": {"header": "bold on-"}}, "unknown summary style token 'on-'"),
            ("invalid border", {"border": "dashed"}, "border none or in"),
            ("invalid color mode", {"color": "sometimes"}, "needs color in"),
            ("string instead of boolean icons", {"icons": "yes"}, "boolean icons"),
            ("array instead of theme object", [], "summary theme must be an object"),
            ("numeric style", {"styles": {"header": 3}}, "to style strings"),
            ("repeated brightness", {"styles": {"header": "bold bright-bright-red"}}, "unknown summary style token 'bright-bright-red'"),
            ("short RGB", {"styles": {"header": "bold #fff"}}, "unknown summary style token '#fff'"),
            ("unhashable border", {"border": []}, "border none or in"),
            ("unhashable color mode", {"color": {}}, "needs color in"),
            ("unknown element", {"styles": {"footer": "bold"}}, "summary theme styles must map"),
            ("unknown key", {"colour": "never"}, "summary theme must be an object"),
            ("unknown token even with color off", {"styles": {"header": "bold blink"}, "color": "never"}, "unknown summary style token 'blink'"),
        )
        self.assertEqual(load({"styles": {"header": "underline"}})["styles"]["header"], "\x1b[4m")
        for name, theme, error in cases:
            with self.subTest(name), self.assertRaisesRegex(ValueError, re.escape(error)):
                load(theme)

    def test_color_policy_controls_which_streams_get_styled(self):
        cases = (
            ("always overrides redirected output and NO_COLOR", "always", io.StringIO(), {"NO_COLOR": "1"}, True),
            ("auto ignores empty NO_COLOR", "auto", Terminal(), {"NO_COLOR": ""}, True),
            ("auto respects NO_COLOR", "auto", Terminal(), {"NO_COLOR": "1"}, False),
        )
        for name, mode, stream, environment, styled in cases:
            with self.subTest(name):
                self.assertEqual(load({"color": mode}, stream, environment)["styles"].get("header"), "\x1b[1m" if styled else None)

    def test_no_theme_file_stays_plain_on_a_terminal(self):
        self.assertEqual(summary_theme.load(None, Terminal(), {}), {
            "border": None, "icons": {"headline": "", "warning": "⚠ "}, "styles": {},
        })

    def test_default_theme_output_is_unchanged(self):
        self.assertEqual(query.render_summary(self.report, (), load({}, io.StringIO())), self.plain)

    def test_styles_keep_alignment(self):
        styled = query.render_summary(self.report, (), load({"color": "always", "styles": {"label": "italic #102030", "number": "cyan"}}))
        self.assertIn("\x1b[1m\x1b[3;38;2;16;32;48mTotal\x1b[0m", styled)  # total, then the label column's own style
        self.assertIn("\x1b[3;38;2;16;32;48mMain\x1b[0m", styled)
        self.assertIn("\x1b[2m—\x1b[0m", styled)
        self.assertIn("\x1b[33m⚠ credits unknown", styled)
        self.assertEqual(SGR.sub("", styled), self.plain)

    def test_each_border_closes_one_box_and_turns_the_rule_into_a_junction(self):
        plain_lines = self.plain.splitlines()
        rule = next(index for index, line in enumerate(plain_lines) if set(line) == {"-"})
        # Pin the public border names and glyphs rather than trusting the renderer's table.
        borders = (
            ("ascii", "+-+|++++"),
            ("double", "╔═╗║╠╣╚╝"),
            ("heavy", "┏━┓┃┣┫┗┛"),
            ("rounded", "╭─╮│├┤╰╯"),
            ("single", "┌─┐│├┤└┘"),
        )
        for name, (corner, horizontal, corner_right, vertical, tee, tee_right, bottom, bottom_right) in borders:
            with self.subTest(border=name):
                lines = query.render_summary(self.report, (), load({"border": name, "color": "never", "icons": True})).splitlines()
                self.assertEqual(len({len(line) for line in lines}), 1)
                self.assertEqual([line[0] + line[-1] for line in lines],
                                 [corner + corner_right, *[vertical * 2] * rule, tee + tee_right,
                                  *[vertical * 2] * (len(plain_lines) - rule - 1), bottom + bottom_right])
                self.assertEqual(lines[rule + 1], tee + horizontal * (len(lines[0]) - 2) + tee_right)
                self.assertTrue(lines[1].startswith(vertical + " \uf080 Kiro usage"))
                self.assertTrue(lines[-2].startswith(vertical + " \uf071 credits unknown"))

    def test_external_runs_share_the_card_border(self):
        """One colored box has a rule above each Total, with the same content as the plain card."""
        captures = self.report["captures"]
        external = (1, {**captures, "credit_discount": {**captures["credit_discount"], "eligible": 1, "percentage": 25}})
        plain = query.render_summary(self.report, external=external)
        theme = load({"border": "rounded", "color": "always", "styles": {"muted": "cyan"}})
        colored = query.render_summary(self.report, theme=theme, external=external)
        lines = SGR.sub("", colored).splitlines()
        self.assertIn("\x1b[1mExternal runs\x1b[0m", colored)
        self.assertIn("\x1b[36m1 session\x1b[0m", colored)
        self.assertEqual(len({len(line) for line in lines}), 1)
        self.assertEqual([line[0] + line[-1] for line in lines if line[0] != "│"],
                         ["╭╮", "├┤", "├┤", "╰╯"])
        self.assertEqual([lines[index - 1][0] for index, line in enumerate(lines) if line.startswith("│ Total")],
                         ["├", "├"])
        self.assertEqual([line[2:-2].rstrip() for line in lines if line[0] == "│"],
                         [line for line in plain.splitlines() if set(line) != {"-"}])
        self.assertIn("\nExternal runs\n1 session\n\nModel ", plain)
        own, nested = plain.split("\nExternal runs\n")
        self.assertNotIn("Discount", own)
        self.assertEqual(nested.count("Discount"), 2)
        self.assertRegex(nested, r"\nTotal .* ~25%\n")
        history = report.render({"since": None, "until": None, "captures": self.report["captures"]})
        self.assertEqual(history.splitlines()[1:], self.plain.splitlines()[1:])

    def test_estimated_error_cells_keep_alignment_in_a_box(self):
        """± is part of an estimated Cached or Cache hit cell's text, so colored and bordered rows stay aligned."""
        fixture = test_query.QueryTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        model = "claude-opus-5.5"
        rates = {"credit_error": .1, "fixed_per_call": 1, "hit_input": .000125, "miss_input": .00025, "output": .001}
        with patch.dict(query.credit_discount.RATES, {model: rates}), patch.dict(query.credit_discount.WINDOWS, {model: 1_000_000}):
            # A no-output full hit costs 1 + 3.75 credits; the 3,800-token error rounds to 13%.
            fixture.estimable("one", 4.75, model=model)
            report = query.query(fixture.db, "sess_root")
        never = query.render_summary(report, (), load({"border": "rounded", "color": "never"}))
        always = query.render_summary(report, (), load({"border": "rounded", "color": "always"}))
        self.assertEqual(SGR.sub("", always), never)
        self.assertEqual(len({len(line) for line in never.splitlines()}), 1)
        self.assertRegex(never, r"│ Total\s+1\s+4\.75\s+~30\.0K\s+~0\s+~30\.0K ±13%\s+~100% ±13%\s+│")
        self.assertIn("\x1b[2m~30.0K ±", always)  # one estimate style over the whole cell


if __name__ == "__main__":
    unittest.main()
