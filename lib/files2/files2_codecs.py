"""Document codecs used by the files2 value renderer."""

import json


FORMATS = ("json", "toml", "yaml")


def serialize(format_name, document):
    if format_name == "json":
        return (json.dumps(document, sort_keys=True, ensure_ascii=False) + "\n").encode()
    if format_name == "toml":
        import tomlkit

        return tomlkit.dumps(document).encode()
    if format_name == "yaml":
        import yaml

        return yaml.safe_dump(document, sort_keys=False, allow_unicode=True).encode()
    raise ValueError(f"unsupported document format: {format_name}")


if __name__ == "__main__":
    import sys

    sys.stdout.buffer.write(serialize(sys.argv[1], json.load(sys.stdin)))
