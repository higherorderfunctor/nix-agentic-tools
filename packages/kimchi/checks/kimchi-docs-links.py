#!/usr/bin/env python3

import importlib.util
import sys
import unittest


spec = importlib.util.spec_from_file_location("fetch_docs", sys.argv.pop(1))
fetch_docs = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(fetch_docs)


class LinksFromTests(unittest.TestCase):
    def test_resolves_same_site_links_and_excludes_external_links(self):
        index_url = "https://docs.kimchi.dev/docs/llms.txt"
        body = b"""
[Root relative](/docs/root.md)
[Path relative](relative.md)
[Absolute](https://docs.kimchi.dev/docs/absolute.md)
[External](https://example.com/docs/external.md)
"""

        self.assertEqual(
            fetch_docs.links_from(index_url, body),
            [
                ("page", "https://docs.kimchi.dev/docs/absolute.md"),
                ("page", "https://docs.kimchi.dev/docs/relative.md"),
                ("page", "https://docs.kimchi.dev/docs/root.md"),
            ],
        )


if __name__ == "__main__":
    unittest.main()
