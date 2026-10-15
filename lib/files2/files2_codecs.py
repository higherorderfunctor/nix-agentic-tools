"""Document codecs used by the files2 merge engine and value renderer."""

import json
import re


FORMATS = ("json", "toml", "yaml")


def parse(format_name, data):
    text = data.decode("utf-8")
    if format_name == "json":
        match = re.match(r"(?:[ \t]*//[^\n]*(?:\n|$))*", text)
        prefix = match.group()
        document = json.loads(text[len(prefix):])
        comments = bool(prefix)
    elif format_name == "toml":
        import tomlkit

        document = tomlkit.parse(text)
        prefix = ""
        comments = "#" in text
    elif format_name == "yaml":
        import yaml

        if any(isinstance(token, (yaml.tokens.AliasToken, yaml.tokens.AnchorToken)) for token in yaml.scan(text)):
            raise ValueError("YAML aliases and anchors are unsupported")
        document = yaml.safe_load(text)
        prefix = ""
        comments = False
    else:
        raise ValueError(f"unsupported document format: {format_name}")
    if not hasattr(document, "items"):
        raise ValueError(f"{format_name} document root must be a map")
    return document, prefix, comments


def serialize(format_name, document, prefix=""):
    if format_name == "json":
        return (prefix + json.dumps(document, sort_keys=True, ensure_ascii=False) + "\n").encode()
    if format_name == "toml":
        import tomlkit

        return tomlkit.dumps(document).encode()
    if format_name == "yaml":
        import yaml

        return yaml.safe_dump(document, sort_keys=False, allow_unicode=True).encode()
    raise ValueError(f"unsupported document format: {format_name}")


def plain(value):
    if hasattr(value, "unwrap"):
        value = value.unwrap()
    if hasattr(value, "items"):
        return {key: plain(item) for key, item in value.items()}
    if isinstance(value, list):
        return [plain(item) for item in value]
    return value


def leaves(document, path=()):
    for key, value in document.items():
        address = path + (key,)
        if hasattr(value, "items"):
            yield from leaves(value, address)
        else:
            yield address, plain(value)


if __name__ == "__main__":
    import sys

    sys.stdout.buffer.write(serialize(sys.argv[1], json.load(sys.stdin)))
