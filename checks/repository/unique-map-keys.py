#!/usr/bin/env python3
"""Reject repeated keys in repository data formats using the stock parsers."""

import json
import re
import subprocess
import sys
import tomllib
from pathlib import Path

import json5
import yaml

NIX_INSTANTIATE = "@nixInstantiate@"
FINDINGS: list[str] = []


class Map:
    def __init__(self, pairs, lines=None):
        self.pairs = pairs
        self.lines = lines if lines is not None else []

    def line(self, key):
        matches = [line for candidate, line in self.lines if candidate == key]
        return matches[-1] if matches else None


def pointer(key):
    return str(key).replace("~", "~0").replace("/", "~1")


def keep_pairs(pairs):
    return Map(pairs)


def without_duplicate_keys(pairs):
    kept = []
    for pair in pairs:
        if not any(pair[0] == old[0] for old in kept):
            kept.append(pair)
    return kept


def scan(value, path, filename, physical_line=None):
    if isinstance(value, Map):
        seen = []
        for key, child in value.pairs:
            key_path = f"{path}/{pointer(key)}"
            if any(key == previous for previous in seen):
                line = value.line(key) or physical_line
                location = f" (line {line})" if line is not None else ""
                finding = f"{filename}: duplicate key {key_path}{location}"
                FINDINGS.append(finding)
            else:
                seen.append(key)
            scan(child, key_path, filename, physical_line)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            scan(child, f"{path}/{index}", filename, physical_line)


def strip_jsonc(text):
    def replace(match):
        token = match.group(0)
        if token.startswith("/"):
            return "".join("\n" if char == "\n" else " " for char in token)
        return token

    string_or_comment = r'"(?:\\.|[^"\\])*"'
    comment = r"(//[^\n]*|/\*.*?\*/)"
    without_comments = re.sub(
        rf"{string_or_comment}|{comment}", replace, text, flags=re.S
    )
    return re.sub(
        rf"{string_or_comment}|,(\s*[}}\]])",
        lambda match: match.group(0)
        if match.group(0).startswith('"')
        else match.group(1),
        without_comments,
    )


def parse_json_text(text, filename, label="", physical_line=None):
    try:
        document = json.loads(text, object_pairs_hook=keep_pairs)
        scan(document, "", filename, physical_line)
    except (json.JSONDecodeError, ValueError) as error:
        FINDINGS.append(f"{filename}: parse error{label}: {error}")


def parse_json5(text, filename):
    try:
        json5.loads(text, allow_duplicate_keys=False)
    except ValueError as error:
        if "Duplicate key" not in str(error):
            FINDINGS.append(f"{filename}: parse error: {error}")
            return
    scan(json5.loads(text, object_pairs_hook=keep_pairs), "", filename)


def merge_pairs(value):
    if isinstance(value, Map):
        return value.pairs
    if isinstance(value, list):
        return without_duplicate_keys(
            [pair for item in value for pair in merge_pairs(item)]
        )
    return []


class MappingLoader(yaml.SafeLoader):
    pass


def yaml_mapping(loader, node):
    merged = []
    explicit = []
    lines = []
    for key_node, value_node in node.value:
        value = loader.construct_object(value_node, True)
        if key_node.tag == "tag:yaml.org,2002:merge":
            merged.extend(merge_pairs(value))
        else:
            key = loader.construct_object(key_node, True)
            explicit.append((key, value))
            lines.append((key, key_node.start_mark.line + 1))

    non_overridden = [
        pair
        for pair in without_duplicate_keys(merged)
        if not any(pair[0] == key for key, _ in explicit)
    ]
    return Map(non_overridden + explicit, lines)


MappingLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, yaml_mapping
)


def parse_yaml_text(text, filename):
    try:
        documents = list(yaml.load_all(text, Loader=MappingLoader))
    except yaml.YAMLError as error:
        FINDINGS.append(f"{filename}: parse error: {error}")
        return
    for document in documents:
        scan(document, "", filename)


def parse_markdown(text, filename):
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return
    closings = [
        index
        for index, line in enumerate(lines[1:], 1)
        if line.strip() in {"---", "..."}
    ]
    if not closings:
        return
    frontmatter = "\n" + "\n".join(lines[1 : closings[0]])
    parse_yaml_text(frontmatter, filename)


TOML_DUPLICATES = ("Cannot overwrite", "Cannot declare", "Duplicate inline")


def parse_toml_text(text, filename):
    try:
        tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        is_duplicate = any(message in str(error) for message in TOML_DUPLICATES)
        kind = "duplicate key" if is_duplicate else "parse error"
        FINDINGS.append(f"{filename}: {kind}: {error}")


def first_error(result):
    lines = result.stderr.splitlines()
    errors = [line for line in lines if line.startswith("error:")]
    if errors:
        return errors[0]
    return lines[0] if lines else "nix-instantiate failed without a diagnostic"


def nix_finding(filename, result):
    message = first_error(result)
    attribute = re.search(r"attribute '([^']+)'", message)
    kind = f"duplicate key /{pointer(attribute.group(1))}" if attribute else "parse error"
    location = re.search(r" at (\S+):(\d+):(\d+)", result.stderr)
    if location:
        message = re.sub(r"\s+at \S+:\d+:\d+\s*$", "", message)
        message = f"{message} at {filename}:{location.group(2)}:{location.group(3)}"
    return f"{filename}: {kind}: {message}"


def parse_nix(files):
    batch = subprocess.run(
        [NIX_INSTANTIATE, "--parse", "--store", "dummy://", *files],
        capture_output=True,
        text=True,
    )
    if batch.returncode == 0:
        return
    for filename in files:
        result = subprocess.run(
            [NIX_INSTANTIATE, "--parse", "--store", "dummy://", filename],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            FINDINGS.append(nix_finding(filename, result))


def parse_jsonl(text, filename):
    for number, line in enumerate(text.splitlines(), 1):
        parse_json_text(line, filename, f" on line {number}", number)


PARSERS = {
    ".json": parse_json_text,
    ".jsonc": lambda text, filename: parse_json_text(strip_jsonc(text), filename),
    ".json5": parse_json5,
    ".jsonl": parse_jsonl,
    ".yaml": parse_yaml_text,
    ".yml": parse_yaml_text,
    ".md": parse_markdown,
    ".toml": parse_toml_text,
    ".lock": parse_toml_text,
}


def main(argv):
    nix_files = []
    for filename in argv:
        path = Path(filename)
        suffix = path.suffix
        try:
            # is_file follows valid symlinks and skips dangling tracked symlinks.
            if not path.is_file():
                continue
            text = path.read_text()
            if suffix == ".nix":
                nix_files.append(filename)
            elif suffix == ".lock" and text.lstrip()[:1] == "{":
                parse_json_text(text, filename)
            else:
                PARSERS[suffix](text, filename)
        except (OSError, UnicodeError, ValueError, TypeError, yaml.YAMLError) as error:
            FINDINGS.append(f"{filename}: parse error: {error}")
    parse_nix(nix_files)
    for finding in FINDINGS:
        print(finding, file=sys.stderr)
    return 1 if FINDINGS else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
