"""Prove the Slack extractor refuses specific degradations of the pinned page."""

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
    def test_degraded_pages_fail_with_their_reason(self):
        # The public scope is the first link in its row. Remove its trailing
        # separator so the remaining search row stays well-formed.
        search_public = re.search(r"^\[`search:read\.public`\]\([^)]*\), ", document, re.MULTILINE).group(0)
        last_scopes = SCOPE_LINE.findall(document)[-1]
        # The callout closing the table: a heading line, then one paragraph.
        callout = re.search(r"^Consider using PKCE\n\n.*\n", document, re.MULTILINE).group(0)
        mutations = [
            ("accepts a plaintext transport URL", "transport endpoint 'http://mcp.slack.com/mcp' is not one https url", document.replace(
                "https://mcp.slack.com/mcp\n```", "http://mcp.slack.com/mcp\n```"
            )),
            ("accepts a table without a baseline read scope", "missing required scopes ['search:read.public']", document.replace(
                search_public, ""
            )),
            ("accepts a tool with no scope line", "incomplete tool row before 'Consider using PKCE': 'Upload a file'", document.replace(
                last_scopes, "", 1
            )),
            ("accepts an unmarked end of table", "expected exactly one 'Consider using PKCE' line closing the tool table", document.replace(
                "Consider using PKCE", "Note"
            )),
            ("accepts nine valid rows as a full table", "expected at least 10 tools, found 9", keep_rows(document, 9)),
            ("ignores a stray scope link beyond the first callout paragraph", "scope link outside the tool table: '[`chat:write`]", document.replace(
                callout, callout + "\n[`chat:write`](https://docs.slack.dev/x.md)\n", 1
            )),
        ]
        for regression, message, text in mutations:
            with self.subTest(regression=regression):
                result = extract(text)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertRegex(result.stderr, rf"^slack-mcp-extract: .*{re.escape(message)}")


unittest.main()
