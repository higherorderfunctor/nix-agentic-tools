#!/usr/bin/env python3
"""Reject repeated keys in repository data formats using the stock parsers."""

import json
import subprocess
import sys
import tomllib
from pathlib import Path

import json5
import yaml

NIX_INSTANTIATE = "@nixInstantiate@"
FINDINGS: list[str] = []


class Map:
    def __init__(self, pairs, lines=()):
        self.pairs = pairs
        self.lines = lines


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
        seen = set()
        for index, (key, child) in enumerate(value.pairs):
            key_path = f"{path}/{pointer(key)}"
            if key in seen:
                line = value.lines[index] if value.lines else physical_line
                location = f" (line {line})" if line is not None else ""
                FINDINGS.append(f"{filename}: duplicate key {key_path}{location}")
            else:
                seen.add(key)
            scan(child, key_path, filename, physical_line, visited)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            scan(child, f"{path}/{index}", filename, physical_line, visited)


def parse_json_text(text, filename, line=None):
    try:
        document = json.loads(text, object_pairs_hook=Map)
        scan(document, "", filename, line)
    except ValueError as error:
        where = f" on line {line}" if line is not None else ""
        FINDINGS.append(f"{filename}: parse error{where}: {error}")


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
    lines = text.removeprefix("\ufeff").splitlines()
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


def nix_diagnostic(stderr, filenames):
    lines = stderr.splitlines()[:2]
    for filename in filenames:
        lines = [line.replace(str(Path(filename).resolve()), filename) for line in lines]
    return lines


def parse_nix(files):
    # Refuses an empty selection: with no file argument nix-instantiate parses
    # ./default.nix, which is not a selected file.
    if not files:
        return
    batch = subprocess.run(
        [NIX_INSTANTIATE, "--parse", "--store", "dummy://", *files],
        capture_output=True,
        text=True,
    )
    if batch.returncode == 0:
        return
    before = len(FINDINGS)
    for filename in files:
        result = subprocess.run(
            [NIX_INSTANTIATE, "--parse", "--store", "dummy://", filename],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            FINDINGS.extend(nix_diagnostic(result.stderr, [filename]))
    if len(FINDINGS) == before:
        FINDINGS.extend(nix_diagnostic(batch.stderr, files))


def parse_jsonl(text, filename):
    for number, line in enumerate(text.split("\n"), 1):
        if line:
            parse_json_text(line, filename, number)


PARSERS = {
    "json": parse_json_text,
    "json5": parse_json5,
    "jsonc": parse_json5,
    "jsonl": parse_jsonl,
    "lock": parse_toml_text,
    "md": parse_markdown,
    "toml": parse_toml_text,
    "yaml": parse_yaml_text,
    "yml": parse_yaml_text,
}


def main(argv):
    nix_files = []
    for filename in argv:
        extension = filename.rsplit(".", 1)[-1]
        try:
            if extension == "nix":
                nix_files.append(filename)
                continue
            text = Path(filename).read_text()
            if extension == "lock" and text.lstrip()[:1] == "{":
                parse_json_text(text, filename)
            else:
                PARSERS[extension](text, filename)
        except (ValueError, RecursionError) as error:
            FINDINGS.append(f"{filename}: parse error: {error}")
    parse_nix(nix_files)
    for finding in FINDINGS:
        print(finding, file=sys.stderr)
    return 1 if FINDINGS else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
