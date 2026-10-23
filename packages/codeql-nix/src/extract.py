"""Installed coordinator: one authenticated snapshot and run for both producers."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import time


def digest(value):
    return hashlib.sha256(value).hexdigest()


class RunIdentity:
    def __init__(self, row):
        self.row = row

    @staticmethod
    def snapshot(abi, manifest):
        roots = sorted((root["logicalName"], root["rootContentIdentity"],
                        sorted((entry["path"], entry["contentHash"]) for entry in root["files"]))
                       for root in manifest["roots"])
        return digest(abi.canonical(roots).encode())

    @classmethod
    def syntax(cls, abi, binary, schema, pins, manifest):
        schema_hash = digest(Path(schema).read_bytes())
        sources = Path(__file__).parent
        implementation = [Path(binary), Path(__file__), sources / "syntax.py"]
        implementation += sorted((sources / "eval").rglob("*.nix")) + sorted((sources / "eval").glob("*.py"))
        extractor = digest(b"".join(path.read_bytes() for path in implementation))
        snapshot = cls.snapshot(abi, manifest)
        return cls(["nx_runs", [abi.key("run", [schema_hash, extractor, snapshot]), schema_hash,
                    extractor, json.loads(Path(pins).read_text())["grammar"], "not-requested", snapshot]])

    @classmethod
    def evaluation(cls, abi, supervisor):
        path = Path(supervisor)
        return cls(["nx_runs", [abi.key("run", [str(time.time_ns())]),
                    digest((path.parents[2] / "schema/contract.json").read_bytes()),
                    digest(path.read_bytes() + path.with_name("protocol.py").read_bytes()),
                    "not-requested", "not-requested", "not-admitted"]])

    def check_syntax(self, abi, manifest):
        abi.require(self.row[1][-1] == self.snapshot(abi, manifest), "mixed-source-snapshot")

    def check_targets(self, abi, manifest):
        abi.require(all(target["fingerprint"]["sourceSnapshotHash"] == self.row[1][-1]
                        for target in manifest["targets"].values()), "mixed-source-snapshot")

    def accept(self, abi, packet):
        """Reject an otherwise valid child envelope carrying any other run/snapshot."""
        abi.validate(packet["facts"])
        abi.require([row for row in packet["facts"] if row[0] == "nx_runs"] == [self.row],
                    "mixed-source-snapshot")
        return [row for row in packet["facts"] if row[0] != "nx_runs"]


def copy_source(source, destination, excluded):
    # qltest writes a database beneath its source root while this hook runs.
    # Engine-owned outputs are not admitted source bytes.
    def ignore(directory, names):
        return [name for name in names if Path(directory) / name in excluded]
    shutil.copytree(source, destination, symlinks=True, ignore=ignore)


def main():
    # Keep the same source layout in the installed product: F1/F2 remain the
    # only serialization authority, rather than a coordinator-specific schema.
    sys.path.insert(0, str(Path(__file__).parent / "eval"))
    from protocol import abi, envelope
    from supervisor import execute, nix_command, nix_string, publish, supervise, validate
    import syntax

    binary, schema, combined, pins, nix = sys.argv[1:]
    root = Path(os.environ.get("CODEQL_EXTRACTOR_NIX_SOURCE_ROOT", os.environ.get("LGTM_SRC", os.getcwd()))).resolve(strict=True)
    trap = Path(os.environ["CODEQL_EXTRACTOR_NIX_TRAP_DIR"])
    trap.mkdir(parents=True, exist_ok=True)
    budget = {"maxBytes": 8 * 1048576, "maxMemoryMiB": 2048, "maxSeconds": 60}
    syntax_manifest = {"roots": []}
    # Even discovery failures have a schema-bearing run and explicit health.
    identity = RunIdentity.syntax(abi, binary, combined, pins, syntax_manifest)
    phase = "discovery"
    original_root = root
    snapshots = tempfile.TemporaryDirectory(prefix="nixql-snapshot-")
    excluded = {Path(os.environ[key]).absolute() for key in (
        "CODEQL_EXTRACTOR_NIX_WIP_DATABASE", "CODEQL_EXTRACTOR_NIX_TRAP_DIR",
        "CODEQL_EXTRACTOR_NIX_SOURCE_ARCHIVE_DIR", "CODEQL_EXTRACTOR_NIX_SCRATCH_DIR") if key in os.environ}
    try:
        root = Path(snapshots.name) / "source"
        copy_source(original_root, root, excluded)
        inputs = json.loads(os.environ.get("CODEQL_EXTRACTOR_NIX_OPTION_INPUTS", "{}"))
        abi.require(isinstance(inputs, dict), "inputs must be a pinned root map")
        roots = {None: {"path": str(root)}}
        for name, entry in inputs.items():
            abi.text(name)
            abi.require(bool(name) and set(entry) == {"path", "narHash"}, "invalid pinned input")
            abi.require(Path(entry["path"]).is_absolute(), "input path must be absolute")
            roots[name] = dict(entry)
        with tempfile.TemporaryDirectory(prefix="nixql-discovery-") as temporary:
            scratch = Path(temporary)
            env = {"HOME": temporary, "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
                   "NIX_CONF_DIR": temporary, "NIX_USER_CONF_FILES": "", "PATH": os.defpath,
                   "TMPDIR": temporary, "XDG_CACHE_HOME": temporary, "XDG_CONFIG_HOME": temporary}
            deadline = time.monotonic() + budget["maxSeconds"]
            for name, entry in roots.items():
                path = Path(entry["path"]).resolve(strict=True)
                abi.require(path.is_dir(), "input root must be a directory")
                entry["path"] = str(path)
                actual = execute([nix, "--extra-experimental-features", "nix-command", "hash", "path", str(path)],
                                 {}, budget, scratch, deadline, env).strip()
                abi.require("narHash" not in entry or entry["narHash"] == actual, "source-snapshot-mismatch")
                entry["narHash"] = actual
            target_path = Path(os.environ.get("CODEQL_EXTRACTOR_NIX_OPTION_TARGETS", root / ".nixql/targets.nix"))
            if not target_path.is_absolute():
                target_path = root / target_path
            elif target_path.is_relative_to(original_root):
                target_path = root / target_path.relative_to(original_root)
            job = {"sourcePins": {entry["path"]: entry["narHash"] for entry in roots.values()},
                   "target": {"sourceRoots": [{"path": entry["path"]} for entry in roots.values()]}}

            def discovery(imported, trees):
                handles = " ".join(nix_string(name) + " = " + tree + ";" for name, tree in zip(roots, trees) if name is not None)
                return "let trees = [ " + " ".join("(" + tree + ").outPath" for tree in trees) + " ]; in { result = " + imported + " { inputs = { " + handles + " }; source = builtins.toPath (builtins.head trees); }; inherit trees; }"

            argv = nix_command(nix, {"expression": str(target_path)}, job, budget, scratch, deadline, env, discovery)
            discovered = json.loads(execute(argv, job, budget, scratch, deadline, env))
            reverse = dict(zip(discovered["trees"], (entry["path"] for entry in roots.values())))

            def restore(value):
                if isinstance(value, str):
                    for copied, original in reverse.items():
                        if value == copied or value.startswith(copied + "/"):
                            return original + value[len(copied):]
                if isinstance(value, dict):
                    return {key: restore(item) for key, item in value.items()}
                if isinstance(value, list):
                    return list(map(restore, value))
                return value

            result = restore(discovered["result"])
        abi.require(set(result) == {"manifest", "bindings"} and isinstance(result["bindings"], dict), "invalid target result")
        manifest, bindings = result["manifest"], result["bindings"]
        validate(manifest, "target-manifest.json")
        phase = "syntax"
        for target in manifest["targets"].values():
            for admitted in target["sourceRoots"]:
                matching = next((entry for entry in roots.values() if entry["path"] == admitted["path"]), None)
                abi.require(matching is not None, "source-not-admitted")
                admitted["rootContentIdentity"] = matching["narHash"]
        # Only source-root syntax is selected; dependencies remain pinned inputs,
        # rather than implicitly parsing the entirety of nixpkgs.
        source_roots = {abi.canonical(entry): entry for target in manifest["targets"].values()
                        for entry in target["sourceRoots"] if entry["path"] == str(root)}
        abi.require(bool(source_roots), "source root missing from target closure")
        files = [{"path": path.relative_to(root).as_posix(), "contentHash": digest(path.read_bytes())}
                 for path in sorted(root.rglob("*.nix")) if path.is_file()]
        syntax_manifest["roots"] = [entry | {"path": str(original_root), "files": files, "sourceKind": "project"} for entry in source_roots.values()]
        # Include admitted dependency pins in snapshot identity even though their
        # syntax isn't selected. Empty file selections still retain root hashes.
        for name, entry in roots.items():
            if name is not None:
                syntax_manifest["roots"].append({"logicalName": name, "rootContentIdentity": entry["narHash"],
                                               "path": entry["path"], "sourceKind": "dependency", "files": []})
        identity = RunIdentity.syntax(abi, binary, combined, pins, syntax_manifest)
        for target in manifest["targets"].values():
            target["fingerprint"]["sourceSnapshotHash"] = identity.row[1][-1]
        with tempfile.TemporaryDirectory(prefix="nixql-extraction-") as temporary:
            staged = Path(temporary)
            staged_trap, staged_archive = staged / "trap", staged / "archive"
            code, syntax_packet = syntax.extract(binary, schema, combined, pins, syntax_manifest,
                                                 staged, identity, staged_trap, staged_archive)
            facts = identity.accept(abi, syntax_packet)
            abi.require(code == 0, "syntax-extraction-failed")
            source_files = [row for row in facts if row[0] == "nx_files"]
            phase = "evaluation"
            # fetchTree uses the same content-addressed source spelling in every
            # request's private store. E1 verifies bytes before admitting links.
            copied_project = discovered["trees"][list(roots).index(None)]
            mappings = {}
            for _, (file, _, relative, _, _) in source_files:
                mappings.setdefault(copied_project + "/" + relative, []).append(file)
            evaluation = supervise(manifest, bindings, staged_trap, source_files=source_files,
                                   source_mappings=mappings, nix=nix, identity=identity)
            facts += identity.accept(abi, evaluation)
            unique = list({abi.canonical(row): row for row in [identity.row] + facts}.values())
            envelope(unique)
            failures = [args[2] + ": " + args[3] for relation, args in unique if relation == "nx_diagnostics"]
            incomplete = any(row[1][2] != "complete" for row in unique if row[0] == "nx_phases")
            with tempfile.TemporaryDirectory(prefix="nixql-verify-") as verification:
                deadline = time.monotonic() + budget["maxSeconds"]
                verified_source = Path(verification) / "source"
                copy_source(original_root, verified_source, excluded)
                for name, entry in roots.items():
                    path = str(verified_source) if name is None else entry["path"]
                    actual = execute([nix, "--extra-experimental-features", "nix-command", "hash", "path", path],
                                     {}, budget, Path(verification), deadline, env | {"HOME": verification, "TMPDIR": verification}).strip()
                    abi.require(actual == entry["narHash"], "mixed-source-snapshot")
            archive = Path(os.environ["CODEQL_EXTRACTOR_NIX_SOURCE_ARCHIVE_DIR"])
            for source, destination in ((staged_archive, archive), (staged_trap, trap)):
                for path in sorted(source.rglob("*")):
                    if path.is_file():
                        syntax.atomic(destination / path.relative_to(source), path.read_bytes())
        publish(trap, "coordinator", [identity.row])
        if incomplete:
            print("nixql: incomplete extraction: " + "; ".join(failures), file=sys.stderr)
        return int(incomplete)
    except Exception as error:
        run = identity.row[1][0]
        message = str(error).encode("utf-8", errors="replace")[:4096].decode("utf-8", errors="ignore")
        facts = [identity.row, ["nx_phases", [run, phase, "failed", "extraction-refused"]],
                 ["nx_diagnostics", [abi.key("diagnostic", [run, "coordinator"]), run, "extraction-refused", message]]]
        facts += [["nx_phases", [run, completed, "complete", ""]]
                  for completed in ("discovery", "syntax") if completed != phase and
                  (phase == "evaluation" or completed == "discovery" and phase == "syntax")]
        envelope(facts)
        publish(trap, "coordinator", facts)
        print("nixql: " + message, file=sys.stderr)
        return 1
    finally:
        snapshots.cleanup()


if __name__ == "__main__":
    sys.exit(main())
