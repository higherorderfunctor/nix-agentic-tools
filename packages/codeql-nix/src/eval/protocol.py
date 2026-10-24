"""F2 transport checks using F1's exact-text and fact authority."""

import importlib.util
import json
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker

SCHEMA = Path(__file__).resolve().parents[2] / "schema"
spec = importlib.util.spec_from_file_location("nixql_abi", SCHEMA / "abi.py")
abi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(abi)
formats = FormatChecker()


@formats.checks("nixql-exact-text", raises=(ValueError, UnicodeError))
def exact_text(value):
    return not isinstance(value, str) or abi.text(value) == value


@formats.checks("nixql-native-int")
def native_int(value):
    return type(value) is int and 0 <= value <= 2147483647


@formats.checks("nixql-path", raises=(ValueError, UnicodeError))
def exact_path(value):
    abi.path(value)
    return True


def validate(value, schema):
    Draft202012Validator(json.loads((SCHEMA / schema).read_text()),
                         format_checker=formats).validate(value)
    if schema == "target-manifest.json":
        # JSON Schema cannot key items: each logical name must select one root.
        abi.require(all(len({root["logicalName"] for root in target["sourceRoots"]}) == len(target["sourceRoots"])
                        for target in value["targets"].values()), "duplicate-root-logical-name")


def envelope(facts):
    packet = {"protocolVersion": 1, "facts": facts}
    validate(packet, "observation-protocol.json")
    abi.validate(facts)
    return packet


def trap(facts):
    """Render only validated F1 columns; global labels never mimic syntax labels."""
    labels = {}
    output = []
    for relation, args in facts:
        encoded = []
        for (_, kind), value in zip(abi.COLUMNS[relation], args):
            if kind in abi.CONTRACT["entities"]:
                if value not in labels:
                    label = f"#{len(labels) + 1}"
                    labels[value] = label
                    output.append(f'{label}=@"{value.replace(chr(34), chr(34) * 2)}"\n')
                encoded.append(labels[value])
            elif kind == "text":
                encoded.append('"' + value.replace('"', '""') + '"')
            elif kind == "bool":
                encoded.append("1" if value else "0")
            else:
                encoded.append(str(value))
        output.append(f'{relation}({", ".join(encoded)})\n')
    return "".join(output)
