"""Prove the Slack extractor accepts the pinned page and refuses degraded ones."""

import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

extractor, snapshot = sys.argv.pop(1), Path(sys.argv.pop(1))
document = snapshot.read_text(encoding="utf-8")
SCOPE_LINE = re.compile(r"^\[`.*$", re.MULTILINE)


def extract(text):
    with tempfile.NamedTemporaryFile("w", suffix=".md", encoding="utf-8") as page:
        page.write(text)
        page.flush()
        return subprocess.run(
            [sys.executable, "-I", extractor, page.name],
            capture_output=True, text=True, check=False,
        )


def keep_rows(text, count):
    # Drop every name/scope pair after the first `count` rows.
    lines = text.split("\n")
    scope_lines = [i for i, line in enumerate(lines) if SCOPE_LINE.match(line)]
    cut = scope_lines[count - 1] + 1
    end = scope_lines[-1] + 1
    return "\n".join(lines[:cut] + lines[end:])


class SlackExtraction(unittest.TestCase):
    def test_pinned_page_parses(self):
        result = extract(document)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_degraded_pages_fail_with_their_reason(self):
        # The first link in its row, so it is removed with its trailing separator.
        search_public = re.search(r"\[`search:read.public`\]\([^)]*\), ", document).group(0)
        last_scopes = SCOPE_LINE.findall(document)[-1]
        # The callout closing the table: a heading line, then one paragraph.
        callout = re.search(r"^Consider using PKCE\n\n.*\n", document, re.MULTILINE).group(0)
        mutations = [
            ("is not one https url", document.replace(
                "https://mcp.slack.com/mcp\n```", "http://mcp.slack.com/mcp\n```"
            )),
            ("missing required scopes ['search:read.public']", document.replace(search_public, "")),
            ("incomplete tool row before 'Consider using PKCE': 'Upload a file'", document.replace(
                last_scopes, "", 1
            )),
            ("closing the tool table", document.replace("Consider using PKCE", "Note")),
            ("scope link outside the tool table: '[`chat:write`]", document.replace(
                "Consider using PKCE\n", "Consider using PKCE\n\n[`chat:write`](https://docs.slack.dev/x.md)\n", 1
            )),
            ("expected at least 10 tools, found 9", keep_rows(document, 9)),
            ("scope link outside the tool table: '[`chat:write`]", document.replace(
                callout, callout + "\n[`chat:write`](https://docs.slack.dev/x.md)\n"
            )),
        ]
        for message, text in mutations:
            with self.subTest(message=message):
                self.assertNotEqual(text, document)
                result = extract(text)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertRegex(result.stderr, rf"^slack-mcp-extract: .*{re.escape(message)}")


unittest.main()
