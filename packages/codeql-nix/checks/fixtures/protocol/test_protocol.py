"""F2 acceptance: JSON Schema wire checks followed by the existing F1 validator.

Run from the repository root with Python jsonschema installed. Expectations were
written before the two protocol schemas; no evaluator/serializer is invoked.
"""

from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import unittest

from jsonschema import Draft202012Validator, FormatChecker, ValidationError

from examples import I, MANIFEST, PARTIAL, PRE_TARGET, REFUSAL, golden, result

SCHEMA_DIR = Path(__file__).resolve().parents[3] / "schema"
LIMIT = 1048576
FORMATS = FormatChecker()
spec = importlib.util.spec_from_file_location("abi", SCHEMA_DIR / "abi.py")
abi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(abi)


@FORMATS.checks("nixql-exact-text", raises=(UnicodeError,))
def exact_text(value):
    """Independent format oracle: JSON Schema maxLength counts characters."""
    return isinstance(value, str) and len(value.encode("utf-8")) <= LIMIT


@FORMATS.checks("nixql-native-int")
def native_int(value):
    """F1 native integers exclude JSON numbers parsed as floats or Booleans."""
    return type(value) is int and 0 <= value <= 2147483647


@FORMATS.checks("nixql-path", raises=(UnicodeError,))
def path_array(value):
    return (
        isinstance(value, list)
        and all(isinstance(segment, str) for segment in value)
        and exact_text(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
    )


def descriptor(manifest):
    return manifest["targets"]["host.workstation"]


def row(packet, relation):
    return next(arguments for name, arguments in packet["facts"] if name == relation)


class ProtocolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        validators = []
        for name in ("target-manifest.json", "observation-protocol.json"):
            schema = json.loads((SCHEMA_DIR / name).read_text())
            Draft202012Validator.check_schema(schema)
            validators.append(Draft202012Validator(schema, format_checker=FORMATS))
        cls.manifest_schema, cls.observation_schema = validators

    def manifest(self, packet):
        self.manifest_schema.validate(packet)

    def observations(self, packet):
        self.observation_schema.validate(packet)
        abi.validate(packet["facts"])

    def rejected_manifest(self, packet):
        with self.assertRaises(ValidationError):
            self.manifest(packet)

    def rejected_observations(self, packet):
        with self.assertRaises((ValidationError, ValueError)):
            self.observations(packet)

    def test_explicit_metadata_and_module_descriptors(self):
        self.manifest(MANIFEST)
        self.assertEqual(descriptor(MANIFEST)["observationModes"], ["metadata"])
        self.assertEqual(descriptor(MANIFEST)["requests"][0]["path"], ["services"])
        for kind in ("arguments", "rich-result"):
            packet = deepcopy(MANIFEST)
            descriptor(packet)["evaluation"]["kind"] = kind
            self.manifest(packet)
        self.assertEqual(descriptor(MANIFEST)["fingerprint"]["modelVersion"], "not-requested")
        self.assertEqual(row(result(), "nx_runs")[4], "not-requested")
        # An arbitrary target label is not interpreted as a flake attribute path.
        packet = deepcopy(MANIFEST)
        packet["targets"]["literal.[name].with.dots"] = packet["targets"].pop("host.workstation")
        self.manifest(packet)

    def test_required_explicit_metadata_and_closed_objects(self):
        for field in descriptor(MANIFEST):
            packet = deepcopy(MANIFEST)
            del descriptor(packet)[field]
            self.rejected_manifest(packet)
        for field in ("argumentDescription", "evaluation", "fingerprint"):
            for nested in descriptor(MANIFEST)[field]:
                packet = deepcopy(MANIFEST)
                del descriptor(packet)[field][nested]
                self.rejected_manifest(packet)
        for path in ((), ("targets", "host.workstation"), ("targets", "host.workstation", "evaluation"), ("targets", "host.workstation", "argumentDescription"), ("targets", "host.workstation", "fingerprint"), ("targets", "host.workstation", "sourceRoots", 0)):
            packet = deepcopy(MANIFEST)
            value = packet
            for segment in path:
                value = value[segment]
            value["invented"] = True
            self.rejected_manifest(packet)
        for field, value in (("adapter", "guessed-flake"), ("system", ""), ("inputIdentities", {}), ("observationModes", []), ("sourceRoots", []), ("requests", [])):
            packet = deepcopy(MANIFEST)
            descriptor(packet)[field] = value
            self.rejected_manifest(packet)

    def test_explicit_source_roots_and_input_identities(self):
        for field in ("logicalName", "path", "rootContentIdentity"):
            packet = deepcopy(MANIFEST)
            del descriptor(packet)["sourceRoots"][0][field]
            self.rejected_manifest(packet)
            for value in ("", True):
                packet = deepcopy(MANIFEST)
                descriptor(packet)["sourceRoots"][0][field] = value
                self.rejected_manifest(packet)
        for inputs in ({"": "pin"}, {"nixpkgs": ""}, {"nixpkgs": False}):
            packet = deepcopy(MANIFEST)
            descriptor(packet)["inputIdentities"] = inputs
            self.rejected_manifest(packet)

    def test_metadata_requests_and_deferred_surfaces(self):
        for facet in ("declarations", "isDefined", "priority"):
            packet = deepcopy(MANIFEST)
            descriptor(packet)["requests"][0]["facet"] = facet
            self.manifest(packet)
        for field, value in (
            ("adapter", "nixos"),
            ("observationModes", ["graph"]),
            ("observationModes", ["metadata", "selected-value"]),
            ("reusable", True),
        ):
            packet = deepcopy(MANIFEST)
            descriptor(packet)[field] = value
            self.rejected_manifest(packet)
        for field, value in (
            ("domain", "graph"),
            ("domain", "config"),
            ("domain", "schema"),
            ("facet", "value"),
            ("facet", "all-declarations"),
            ("facet", "internal"),
        ):
            packet = deepcopy(MANIFEST)
            descriptor(packet)["requests"][0][field] = value
            self.rejected_manifest(packet)
        packet = deepcopy(MANIFEST)
        descriptor(packet)["evaluation"]["kind"] = "config-only"
        self.rejected_manifest(packet)
        packet = deepcopy(MANIFEST)
        descriptor(packet)["fingerprint"]["modelVersion"] = "model-a"
        self.rejected_manifest(packet)

    def test_literal_paths_and_every_explicit_budget(self):
        for segments in (["a.b"], ["a", "b"], ["", "é", 'quote"', "a\\b"]):
            packet = deepcopy(MANIFEST)
            descriptor(packet)["requests"][0]["path"] = segments
            self.manifest(packet)
        for segments in ("a.b", [0], [True], [None]):
            packet = deepcopy(MANIFEST)
            descriptor(packet)["requests"][0]["path"] = segments
            self.rejected_manifest(packet)
        for field in ("domain", "path", "facet", "maxDepth", "maxNodes", "maxBytes", "maxSeconds", "maxMemoryMiB"):
            packet = deepcopy(MANIFEST)
            del descriptor(packet)["requests"][0][field]
            self.rejected_manifest(packet)
        for field in ("maxDepth", "maxNodes", "maxBytes", "maxSeconds", "maxMemoryMiB"):
            for value in (-1, True, 1.0, 1.5, 2147483648):
                packet = deepcopy(MANIFEST)
                descriptor(packet)["requests"][0][field] = value
                self.rejected_manifest(packet)

    def test_envelope_and_identity_mapping_cover_all_f1_relations(self):
        packet = {"protocolVersion": 1, "facts": deepcopy(golden.GRAPH)}
        before = deepcopy(packet)
        self.observations(packet)
        self.assertEqual(packet, before)
        self.assertEqual(len({name for name, _ in packet["facts"]}), 25)
        for candidate in (
            {}, {"protocolVersion": 1}, {"facts": []},
            {"protocolVersion": 2, "facts": []},
            {"protocolVersion": 1, "facts": {}},
            {"protocolVersion": 1, "facts": [], "extra": True},
            {"protocolVersion": 1, "facts": [["nx_runs", [], "extra"]]},
            {"protocolVersion": 1, "facts": [["nx_invented", []]]},
        ):
            self.rejected_observations(candidate)
        packet["facts"].append(deepcopy(packet["facts"][0]))
        self.rejected_observations(packet)  # F1 primary-key validation is mandatory.

    def test_every_status_and_pre_target_failure(self):
        for state in ("blocked", "complete", "failed", "partial", "skipped", "unsupported"):
            self.observations(result(state, "" if state == "complete" else "fixture-reason"))
        for state in ("blocked", "failed", "observed", "unforced", "unsupported"):
            self.observations(result("partial", "fixture-reason", state))
        for state in ("not-requested", "supported", "unavailable", "unsupported"):
            packet = result()
            packet["facts"].append(["nx_capabilities", [I["target"], "metadata", state, "fixture-reason"]])
            self.observations(packet)
        for state in ("blocked", "complete", "failed", "not-requested", "partial", "unsupported"):
            packet = result()
            row(packet, "nx_targets")[-1] = state
            self.observations(packet)
        for state in ("complete", "failed", "not-requested", "partial"):
            packet = deepcopy(PRE_TARGET)
            row(packet, "nx_phases")[2] = state
            self.observations(packet)
        for state in ("complete", "excluded", "failed", "recovered"):
            packet = {"protocolVersion": 1, "facts": deepcopy(golden.GRAPH)}
            row(packet, "nx_syntax_results")[1] = state
            self.observations(packet)
        self.observations(PRE_TARGET)
        self.observations(PARTIAL)
        self.observations(REFUSAL)
        packet = deepcopy(REFUSAL)
        row(packet, "nx_request_results")[1] = "complete"
        self.rejected_observations(packet)
        for reason in ("timeout", "text-field-too-large"):
            self.rejected_observations(result("complete", reason))
        self.rejected_observations(result("failed", "threw", "observed"))

    def test_priorities_remain_canonical_decimal_strings(self):
        for text in ("-9223372036854775808", "-1", "0", "1", "9223372036854775807"):
            packet = {"protocolVersion": 1, "facts": deepcopy(golden.GRAPH)}
            row(packet, "nx_option_priority")[1] = text
            self.observations(packet)
        for text in ("-9223372036854775809", "9223372036854775808", "-0", "+1", "01", "1e3", "1.0", 1, True):
            packet = {"protocolVersion": 1, "facts": deepcopy(golden.GRAPH)}
            row(packet, "nx_option_priority")[1] = text
            self.rejected_observations(packet)
        self.observations(result("unsupported", "priority-domain-unsupported"))

    def test_exact_text_utf8_and_json_escaping_boundaries(self):
        for size in (LIMIT - 1, LIMIT, LIMIT + 1):
            for prefix in ("a", "é"):
                text = prefix * (size // len(prefix.encode())) + "a" * (size % len(prefix.encode()))
                self.assertEqual(len(text.encode()), size)
                packet = deepcopy(PRE_TARGET)
                row(packet, "nx_diagnostics")[3] = text
                if size <= LIMIT:
                    self.observations(packet)
                else:
                    self.rejected_observations(packet)
                manifest = deepcopy(MANIFEST)
                descriptor(manifest)["argumentDescription"]["moduleArgumentsRef"] = text
                if size <= LIMIT:
                    self.manifest(manifest)
                else:
                    self.rejected_manifest(manifest)
            # Path arrays additionally contain the brackets around their JSON string.
            manifest = deepcopy(MANIFEST)
            segment = '"' * ((size - 4) // 2) + "a" * ((size - 4) % 2)
            descriptor(manifest)["requests"][0]["path"] = [segment]
            path_size = len(json.dumps([segment], separators=(",", ":")).encode())
            self.assertEqual(path_size, size)
            if path_size <= LIMIT:
                self.manifest(manifest)
            else:
                self.rejected_manifest(manifest)
        manifest = deepcopy(MANIFEST)
        descriptor(manifest)["argumentDescription"]["moduleArgumentsRef"] = "\ud800"
        self.rejected_manifest(manifest)


if __name__ == "__main__":
    unittest.main(verbosity=2)
