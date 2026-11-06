#!/usr/bin/env python3
"""Reject repeated keys in repository data formats using the stock parsers."""
import json, re, subprocess, sys, tomllib
from pathlib import Path
import json5
import yaml
NIX_INSTANTIATE = "@nixInstantiate@"
FINDINGS: list[str] = []
class DuplicateKey(Exception): pass
class Map:
    def __init__(self, pairs, lines=None): self.pairs, self.lines = pairs, lines or {}
def pointer(key): return str(key).replace("~", "~0").replace("/", "~1")
def keep_pairs(pairs): return Map(pairs)
def scan(value, path, filename):
    if isinstance(value, Map):
        seen = set()
        for key, child in value.pairs:
            key_path = f"{path}/{pointer(key)}"
            if key in seen:
                line = f" (line {value.lines[key]})" if key in value.lines else ""
                FINDINGS.append(f"{filename}: duplicate key {key_path}{line}")
            else:
                seen.add(key)
            scan(child, key_path, filename)
    elif isinstance(value, list):
        for child in value:
            scan(child, path, filename)
def strip_jsonc(text):
    def replace(match):
        token = match.group(0)
        if token.startswith("/"):
            return "".join("\n" if char == "\n" else " " for char in token)
        return token
    without_comments = re.sub(r'"(?:\\.|[^"\\])*"|(//[^\n]*|/\*.*?\*/)', replace, text, flags=re.S)
    return re.sub(r'"(?:\\.|[^"\\])*"|,(\s*[}\]])', lambda m: m.group(0) if m.group(0).startswith('"') else m.group(1), without_comments)
def parse_json_text(text, filename, label=""):
    try:
        scan(json.loads(text, object_pairs_hook=keep_pairs), "", filename)
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
class UniqueKeyLoader(yaml.SafeLoader):
    refuse_duplicates = False
def yaml_mapping(loader, node):
    merged, explicit, lines = [], [], {}
    for key_node, value_node in node.value:
        value = loader.construct_object(value_node, True)
        if key_node.tag == "tag:yaml.org,2002:merge": merged.extend(value.pairs if isinstance(value, Map) else value.items())
        else:
            key = loader.construct_object(key_node, True); explicit.append((key, value)); lines[key] = key_node.start_mark.line + 1
    keys = [key for key, _ in explicit]
    if loader.refuse_duplicates and len(keys) != len(set(keys)): raise DuplicateKey
    explicit_keys = set(keys)
    return Map([(key, value) for key, value in merged if key not in explicit_keys] + explicit, lines)
UniqueKeyLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, yaml_mapping)
class StrictUniqueKeyLoader(UniqueKeyLoader):
    refuse_duplicates = True
def parse_yaml_text(text, filename):
    try: documents = list(yaml.load_all(text, Loader=StrictUniqueKeyLoader))
    except DuplicateKey: documents = list(yaml.load_all(text, Loader=UniqueKeyLoader))
    except yaml.YAMLError as error: return FINDINGS.append(f"{filename}: parse error: {error}")
    for document in documents: scan(document, "", filename)
def parse_markdown(text, filename):
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---": return
    closings = [index for index, line in enumerate(lines[1:], 1) if line.strip() in {"---", "..."}]
    if not closings: return FINDINGS.append(f"{filename}: parse error: unterminated YAML frontmatter")
    parse_yaml_text("\n" + "\n".join(lines[1:closings[0]]), filename)
def split_toml_key(text):
    return [part.strip().strip("\"'") for part in re.findall(r'"[^"]*"|\'[^\' ]*\'|[^.]+', text)]
def toml_duplicate(text, error):
    line_number = int(re.search(r"line (\d+)", str(error)).group(1)); lines = text.splitlines(); line = lines[line_number - 1]
    current = re.match(r"\s*\[\[?\s*([^\]]+)", line)
    if current: return "/" + "/".join(pointer(key) for key in split_toml_key(current.group(1)))
    matches = (re.match(r"\s*\[\[?\s*([^\]]+)", candidate) for candidate in reversed(lines[:line_number-1]))
    headers = next((split_toml_key(match.group(1)) for match in matches if match), [])
    keys = split_toml_key(line.split("=", 1)[0])
    if "Duplicate inline table key" in str(error): keys.append(re.search(r"'([^']+)'", str(error)).group(1))
    return "/" + "/".join(pointer(key) for key in headers + keys)
def parse_toml_text(text, filename):
    try: tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        duplicate = any(kind in str(error) for kind in ("Cannot overwrite", "Cannot declare", "Duplicate inline"))
        FINDINGS.append(f"{filename}: {'duplicate key ' + toml_duplicate(text, error) if duplicate else 'parse error'}: {error}")
def parse_nix(files):
    remaining = list(files)
    while remaining:
        result = subprocess.run([NIX_INSTANTIATE, "--parse", *remaining], capture_output=True, text=True)
        if result.returncode == 0:
            return
        message = result.stderr.strip().splitlines()[0]
        failed = next((name for name in remaining if str(Path(name).resolve()) in message), remaining[0])
        attribute = re.search(r"attribute '([^']+)'", message)
        kind = f"duplicate key /{pointer(attribute.group(1))}" if attribute else "parse error"
        location = re.search(r" at (\S+):(\d+):(\d+)", message)
        if location:
            message = f"{message[:location.start()]} at {failed}:{location.group(2)}:{location.group(3)}"
        FINDINGS.append(f"{failed}: {kind}: {message}")
        remaining.remove(failed)
def parse_jsonl(text, filename):
    for number, line in enumerate(text.splitlines(), 1):
        parse_json_text(line, filename, f" on line {number}")
def parse_one(suffix, text, filename):
    parser = {".json": parse_json_text, ".jsonc": lambda value, name: parse_json_text(strip_jsonc(value), name), ".json5": parse_json5,
        ".jsonl": parse_jsonl, ".yaml": parse_yaml_text, ".yml": parse_yaml_text, ".md": parse_markdown, ".toml": parse_toml_text, ".lock": parse_toml_text}
    if suffix not in parser and suffix != ".nix": raise ValueError(f"unsupported extension {suffix}")
    if suffix in parser: parser[suffix](text, filename)
def main(argv):
    nix_files = []
    for filename in argv:
        path, suffix = Path(filename), Path(filename).suffix
        try:
            # A tracked symlink has no bytes of its own; read its target when the link exists.
            if path.is_symlink(): path = path.resolve()
            if not path.is_file(): continue
            text = path.read_text()
            if suffix == ".lock" and text.lstrip()[:1] == "{": parse_json_text(text, filename)
            else: parse_one(suffix, text, filename)
        except (OSError, UnicodeError, ValueError, TypeError, yaml.YAMLError) as error: FINDINGS.append(f"{filename}: parse error: {error}")
        if suffix == ".nix": nix_files.append(filename)
    parse_nix(nix_files)
    for finding in FINDINGS: print(finding, file=sys.stderr)
    return 1 if FINDINGS else 0
if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
