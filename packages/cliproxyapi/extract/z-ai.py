"""Extract z.ai's published chat catalog and Claude Code defaults.

Markdown tables and code fences are parsed before reading their values. Tier
bullets are prose, so neither evaluation nor an AST supplies the mapping; the
regex reads only inline tokens from the explicitly named default paragraph.
"""

import json
import re
import sys
from pathlib import Path

from markdown_it import MarkdownIt


def extract(claude, overview, quick_start):
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
                child.attrGet("href")
                for child in token.children
                if child.type == "link_open"
                and child.attrGet("href").startswith("/api-reference/")
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
                anthropic_urls.append(env["ANTHROPIC_BASE_URL"])
                if not defaults:
                    defaults = env
    if set(mapping) != {"haiku", "opus", "sonnet"}:
        raise ValueError("z.ai must publish all three Claude Code default tiers")
    if not set(mapping.values()) <= set(models):
        raise ValueError("z.ai default tier names a model absent from its chat catalog")
    if len(set(anthropic_urls)) != 1 or not anthropic_urls[0].startswith("https://api.z.ai/"):
        raise ValueError("z.ai documented Anthropic base URLs missing or ambiguous")
    anthropic = anthropic_urls[0]
    urls = []
    for token in parser.parse(quick_start):
        if token.type == "fence" and token.info.startswith("python") and "base_url" in token.content:
            # The example is executable SDK setup code, but executing it would
            # call the API. Python's AST supplies the base_url literal instead.
            import ast

            for node in ast.walk(ast.parse(token.content)):
                if isinstance(node, ast.keyword) and node.arg == "base_url":
                    urls.append(ast.literal_eval(node.value).rstrip("/"))
    if len(set(urls)) != 1:
        raise ValueError("z.ai documented API base URLs missing or ambiguous")
    return {
        "apis": {
            "anthropic": {"base-url": anthropic},
            "chat": {"base-url": urls[0]},
        },
        "claudeDefaults": {
            key: value
            for key, value in defaults.items()
            if key not in {"ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"}
        },
        "claudeModels": dict(sorted(mapping.items())),
        "models": sorted(models),
    }


if __name__ == "__main__":
    print(json.dumps(extract(*(Path(path).read_text() for path in sys.argv[1:])), sort_keys=True))
