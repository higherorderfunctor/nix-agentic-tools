"""Extract z.ai's published chat catalog and Claude Code defaults.

Markdown tables and code fences are parsed before reading their values. Tier
bullets are prose, so neither evaluation nor an AST supplies the mapping; the
regex reads only inline tokens from the explicitly named default paragraph. The
devpack quick start's Protocol/Base URL table carries the Coding Plan endpoints,
kept apart from the general API chat URL.
"""

import json
import re
import sys
from pathlib import Path

from markdown_it import MarkdownIt


def normalize(url):
    # The pages print one endpoint with and without a trailing slash; every
    # extracted URL passes through this step before comparisons and output.
    return url.rstrip("/")


def extract(claude, devpack_quick_start, overview, quick_start):
    parser = MarkdownIt("default")
    models = []
    # Catalog sections classify the tables before their rows are validated:
    # one changed chat reference must not silently remove a non-tier model.
    chat_sections = {"Featured Models", "Text Models"}
    excluded_sections = {"Agents", "Built-in Tools", "Image Generation Models"}
    section = None
    heading = False
    table = False
    header = False
    row = []
    references = []
    for token in parser.parse(overview):
        if token.type == "heading_open":
            heading = True
        elif heading and token.type == "inline":
            section, heading = token.content, False
        elif token.type == "table_open":
            table, header = section not in excluded_sections, True
            if table and section not in chat_sections:
                raise ValueError(f"unclassified z.ai catalog table section: {section}")
        elif token.type == "table_close":
            table = False
        elif table and token.type == "tr_open":
            row, references = [], []
        elif table and token.type == "tr_close":
            if header:
                if row[0] != "Model" or "Resource" not in row:
                    raise ValueError("z.ai chat model table header changed shape")
                header = False
            else:
                if references != ["/api-reference/llm/chat-completion.md"]:
                    raise ValueError(f"unclassified z.ai chat model reference: {row[0]}")
                models.append(row[0].lower())
        elif table and token.type == "inline":
            row.append(token.content)
            references.extend(
                href.removeprefix("https://docs.z.ai")
                for child in token.children
                if child.type == "link_open"
                for href in [child.attrGet("href")]
                if href.startswith(("/api-reference/", "https://docs.z.ai/api-reference/"))
            )
    if not models or len(models) != len(set(models)) or any(
        not re.fullmatch(r"glm-[a-z0-9.-]+", model) for model in models
    ):
        raise ValueError("z.ai chat model table missing, duplicated or malformed")

    tokens = parser.parse(claude)
    defaults = {}
    anthropic_urls = []
    mapping = {}
    in_defaults = False
    for token in tokens:
        if token.type == "inline":
            if "with the default configuration as follows:" in token.content:
                if in_defaults or mapping:
                    raise ValueError("duplicate z.ai default mapping paragraph")
                in_defaults = True
            elif in_defaults and "ANTHROPIC_DEFAULT_" in token.content:
                match = re.fullmatch(
                    r"`ANTHROPIC_DEFAULT_([A-Z]+)_MODEL: (GLM-[a-zA-Z0-9.-]+)`",
                    token.content,
                )
                if match is None or match[1].lower() in mapping:
                    raise ValueError("z.ai default tier bullet changed shape")
                mapping[match[1].lower()] = match[2].lower()
            elif in_defaults and mapping:
                in_defaults = False
        elif token.type == "fence" and '"ANTHROPIC_BASE_URL"' in token.content:
            # The manual JSON example is fenced as bash, with leading shell
            # comments. Decode its JSON object without executing those comments.
            document, _ = json.JSONDecoder().raw_decode(token.content[token.content.index("{"):])
            env = document.get("env", {})
            if "ANTHROPIC_BASE_URL" in env:
                anthropic_urls.append(normalize(env["ANTHROPIC_BASE_URL"]))
                if not defaults:
                    defaults = env
    if set(mapping) != {"haiku", "opus", "sonnet"}:
        raise ValueError("z.ai must publish all three Claude Code default tiers")
    if not set(mapping.values()) <= set(models):
        raise ValueError("z.ai default tier names a model absent from its chat catalog")
    if len(set(anthropic_urls)) != 1 or not anthropic_urls[0].startswith("https://api.z.ai/"):
        raise ValueError("z.ai documented Anthropic base URLs missing or ambiguous")
    anthropic = anthropic_urls[0]
    # The endpoint table is matched by its header, not its section title: the
    # devpack page numbers its sections in bold prose, which no heading carries.
    tables = []
    rows = []
    row = []
    table = False
    for token in parser.parse(devpack_quick_start):
        if token.type == "table_open":
            table, rows = True, []
        elif token.type == "table_close":
            table = False
            tables.append(rows)
        elif table and token.type == "tr_open":
            row = []
        elif table and token.type == "tr_close":
            rows.append(row)
        elif table and token.type == "inline":
            row.append(token)
    endpoint_tables = [
        table_rows
        for table_rows in tables
        if [cell.content for cell in table_rows[0]] == ["Protocol", "Base URL"]
    ]
    if len(endpoint_tables) != 1:
        raise ValueError("z.ai devpack Protocol/Base URL table missing or duplicated")
    endpoints = {}
    for cells in endpoint_tables[0][1:]:
        # markdown-it pads every body row to the header's column count, so both
        # cells are always present; only their contents need validating.
        if len(cells[1].children) != 1 or cells[1].children[0].type != "code_inline":
            raise ValueError(f"z.ai devpack {cells[0].content} endpoint is not a code span")
        if cells[0].content in endpoints:
            raise ValueError(f"duplicate z.ai devpack endpoint protocol: {cells[0].content}")
        endpoints[cells[0].content] = normalize(cells[1].children[0].content)
    for protocol in ("Anthropic Messages", "OpenAI Chat Completions"):
        if protocol not in endpoints:
            raise ValueError(f"z.ai devpack endpoint table lost its {protocol} row")
    if not endpoints["OpenAI Chat Completions"].startswith("https://api.z.ai/"):
        raise ValueError("z.ai devpack chat endpoint left the api.z.ai host")
    if endpoints["Anthropic Messages"] != anthropic:
        raise ValueError("z.ai devpack Anthropic endpoint conflicts with the Claude Code page")
    urls = []
    for token in parser.parse(quick_start):
        if token.type == "fence" and token.info.startswith("python") and "base_url" in token.content:
            # The example is executable SDK setup code, but executing it would
            # call the API. Python's AST supplies the base_url literal instead.
            import ast

            for node in ast.walk(ast.parse(token.content)):
                if isinstance(node, ast.keyword) and node.arg == "base_url":
                    urls.append(normalize(ast.literal_eval(node.value)))
    if len(set(urls)) != 1:
        raise ValueError("z.ai documented API base URLs missing or ambiguous")
    # The three endpoints must stay distinct: a chat URL equal to the Anthropic
    # or the general endpoint would make the vendor default and its override
    # reach the same URL.
    if endpoints["OpenAI Chat Completions"] == anthropic:
        raise ValueError("z.ai devpack chat endpoint duplicates the Anthropic endpoint")
    if endpoints["OpenAI Chat Completions"] == urls[0]:
        raise ValueError("z.ai devpack chat endpoint duplicates the general endpoint")
    return {
        "apis": {
            "anthropic": {"base-url": anthropic},
            "chat": {"base-url": endpoints["OpenAI Chat Completions"]},
        },
        "claudeDefaults": {
            key: value
            for key, value in defaults.items()
            if key not in {"ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"}
        },
        "claudeModels": dict(sorted(mapping.items())),
        "generalApis": {"chat": {"base-url": urls[0]}},
        "models": sorted(models),
    }


if __name__ == "__main__":
    print(json.dumps(extract(*(Path(path).read_text() for path in sys.argv[1:])), sort_keys=True))
