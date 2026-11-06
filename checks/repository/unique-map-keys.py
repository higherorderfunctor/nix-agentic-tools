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


def pointer(key):
    return str(key).replace("~", "~0").replace("/", "~1")


def scan(value, path, filename, physical_line=None, visited=None):
    if visited is None:
        visited = set()
    marker = id(value)
    if marker in visited:
        return
    visited.add(marker)

    if isinstance(value, Map):
        seen = []
        for index, (key, child) in enumerate(value.pairs):
            key_path = f"{path}/{pointer(key)}"
            if any(key == previous for previous in seen):
                line = (
                    value.lines[index]
                    if index < len(value.lines)
                    else physical_line
                )
                location = f" (line {line})" if line is not None else ""
                finding = f"{filename}: duplicate key {key_path}{location}"
                FINDINGS.append(finding)
            else:
                seen.append(key)
            scan(child, key_path, filename, physical_line, visited)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            scan(child, f"{path}/{index}", filename, physical_line, visited)


def parse_json_text(text, filename, label="", physical_line=None):
    try:
        document = json.loads(text, object_pairs_hook=Map)
        scan(document, "", filename, physical_line)
    except ValueError as error:
        FINDINGS.append(f"{filename}: parse error{label}: {error}")


def parse_json5(text, filename):
    scan(json5.loads(text, object_pairs_hook=Map), "", filename)


class MappingLoader(yaml.SafeLoader):
    pass


def yaml_mapping(loader, node):
    pairs = []
    lines = []
    for key_node, value_node in node.value:
        merge = key_node.tag == "tag:yaml.org,2002:merge"
        key = "<<" if merge else loader.construct_object(key_node, True)
        pairs.append((key, loader.construct_object(value_node, True)))
        lines.append(key_node.start_mark.line + 1)
    return Map(pairs, lines)


MappingLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, yaml_mapping
)


def parse_yaml_text(text, filename):
    try:
        documents = list(yaml.load_all(text, Loader=MappingLoader))
    except yaml.YAMLError as error:
        FINDINGS.append(f"{filename}: parse error: {error}")
        return
    visited = set()
    for document in documents:
        scan(document, "", filename, visited=visited)


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


def parse_toml_text(text, filename):
    try:
        tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        FINDINGS.append(f"{filename}: {error}")


def first_error(result):
    lines = result.stderr.splitlines()
    errors = [line for line in lines if line.startswith("error:")]
    if errors:
        return errors[0]
    return lines[0] if lines else "nix-instantiate failed without a diagnostic"


def nix_finding(filename, result):
    message = first_error(result)
    locations = re.findall(r" at (\S+):(\d+):(\d+)", result.stderr)
    if not locations:
        return f"{filename}: {message}"
    location = locations[1] if len(locations) > 1 else locations[0]
    message = re.sub(r"\s+at \S+:\d+:\d+\s*$", "", message)
    return f"{filename}: {message} at {filename}:{location[1]}:{location[2]}"


def parse_nix(files):
    if not files:
        return
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
    ".jsonc": parse_json5,
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
            if suffix == ".nix":
                nix_files.append(filename)
                continue
            text = path.read_text()
            if suffix == ".lock" and text.lstrip()[:1] == "{":
                parse_json_text(text, filename)
            else:
                PARSERS[suffix](text, filename)
        except (OSError, ValueError) as error:
            FINDINGS.append(f"{filename}: parse error: {error}")
    parse_nix(nix_files)
    for finding in FINDINGS:
        print(finding, file=sys.stderr)
    return 1 if FINDINGS else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
