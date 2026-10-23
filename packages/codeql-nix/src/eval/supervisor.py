"""Serialized, bounded F2 projections with atomic validated F1 publication.

Command bindings are explicitly trusted producer fixtures, not a Nix sandbox.
Real expressions run in pure/restricted Nix against hash-pinned admitted roots.
"""

# cspell:ignore preexec RLIMIT setrlimit setsid

import hashlib
import json
import os
from pathlib import Path
import resource
import selectors
import signal
import subprocess
import tempfile
import time
from urllib.parse import quote

from protocol import abi, envelope, trap, validate


class ExtractionFailed(RuntimeError):
    def __init__(self, packet):
        super().__init__("incomplete extraction")
        self.packet = packet


class Refusal(ValueError):
    def __init__(self, code, message, state="failed"):
        super().__init__(message)
        self.code, self.state = code, state


def digest(value):
    return hashlib.sha256(abi.canonical(value).encode()).hexdigest()


def execute(argv, job, request, directory, deadline, env):
    """Drain both pipes without accumulating unbounded output or leaking children."""
    def limits():
        os.setsid()
        memory = request["maxMemoryMiB"] * 1024 * 1024
        resource.setrlimit(resource.RLIMIT_AS, (memory, memory))
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

    with tempfile.TemporaryFile() as source:
        source.write(abi.canonical(job).encode())
        source.seek(0)
        with subprocess.Popen(argv, stdin=source, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, cwd=directory, env=env,
                              preexec_fn=limits) as process:
            streams = {process.stdout: bytearray(), process.stderr: bytearray()}
            try:
                with selectors.DefaultSelector() as selector:
                    for stream in streams:
                        selector.register(stream, selectors.EVENT_READ)
                    while selector.get_map():
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            raise Refusal("timeout", "projection time-limit exceeded")
                        for key, _ in selector.select(min(remaining, 0.1)):
                            data = os.read(key.fileobj.fileno(), 65536)
                            if not data:
                                selector.unregister(key.fileobj)
                                continue
                            streams[key.fileobj].extend(data)
                            if sum(map(len, streams.values())) > request["maxBytes"]:
                                raise Refusal("byte-limit", "projection aggregate output byte limit exceeded")
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise Refusal("timeout", "projection time-limit exceeded")
                    process.wait(timeout=remaining)
            except BaseException as error:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                if isinstance(error, subprocess.TimeoutExpired):
                    raise Refusal("timeout", "projection time-limit exceeded") from error
                raise
            stdout, stderr = (bytes(streams[stream]).decode("utf-8") for stream in streams)
            if process.returncode:
                # These are evaluator refusals, never an absent/false option.
                blocked = any(word in stderr for word in (
                    "forbidden", "not allowed", "does not exist", "No such file",
                    "import-from-derivation", "cannot build", "restricted mode"))
                raise Refusal("evaluation-blocked" if blocked else "projection-failed",
                              stderr or f"producer exited {process.returncode}",
                              "blocked" if blocked else "failed")
            return stdout


def nix_string(value):
    return json.dumps(value, ensure_ascii=False).replace("${", "\\${")


def nix_command(nix, binding, job, request, directory, deadline, env):
    expression = Path(binding["expression"]).resolve(strict=True)
    roots = [Path(root["path"]).resolve(strict=True) for root in job["target"]["sourceRoots"]]
    root = next((root for root in roots if expression.is_relative_to(root)), None)
    if root is None:
        raise Refusal("source-not-admitted", "expression lies outside the admitted closure", "blocked")
    base = [str(nix), "--extra-experimental-features", "nix-command flakes",
            "--store", "local?root=" + str(directory / "store"),
            "--option", "min-free", "0", "--option", "max-jobs", "0",
            "--option", "builders", "", "--option", "substitute", "false"]
    job_root = directory / "job"
    job_root.mkdir()
    (job_root / "job.json").write_text(abi.canonical(job), encoding="utf-8")
    trees, uris = [], []
    for admitted in roots + [job_root]:
        hash_value = execute(base + ["hash", "path", str(admitted)], {}, request,
                             directory, deadline, env).strip()
        # Match Nix's URL spelling exactly; only this pinned local URI is admitted.
        uris.append("path:" + quote(str(admitted), safe="/") + "?narHash=" + quote(hash_value, safe="/"))
        trees.append("builtins.fetchTree { type = \"path\"; path = " + nix_string(str(admitted)) +
                     "; narHash = " + nix_string(hash_value) + "; }")
    selected = trees[roots.index(root)]
    relative = "/" + expression.relative_to(root).as_posix()
    job_source = "builtins.readFile ((" + trees[-1] + ").outPath + \"/job.json\")"
    projection = "(import ((" + selected + ").outPath + " + nix_string(relative) + ")) { job = builtins.fromJSON (" + job_source + "); }"
    return base + ["eval", "--json", "--offline", "--option", "restrict-eval", "true",
                   "--option", "pure-eval", "true", "--option", "allowed-uris", " ".join(uris),
                   "--option", "allow-import-from-derivation", "false",
                   "--expr", projection]


def projection_rows(packet, job, outer):
    validate(packet, "observation-protocol.json")
    facts = packet["facts"]
    permitted = {"nx_member_values", "nx_observation_values", "nx_observations",
                 "nx_request_results", "nx_scalar_values",
                 "nx_value_members", "nx_values"}
    if any(relation not in permitted for relation, _ in facts):
        raise ValueError("producer attempted to overwrite supervisor-owned facts")
    identity, request = job["identities"]["request"], job["request"]
    results = [args for relation, args in facts if relation == "nx_request_results"]
    if len(results) != 1 or results[0][0] != identity:
        raise ValueError("projection must return exactly its supplied request result")
    observations = [args for relation, args in facts if relation == "nx_observations"]
    for _, req, kind, subject, stage, _ in observations:
        if req != identity or kind not in ("config-path", "member") or stage != "applied-config":
            raise ValueError("projection observation escapes the selected request")
        if kind == "config-path" and subject != abi.path(request["path"]):
            raise ValueError("projection selected an unauthorized path")
    envelope(outer + facts)
    values = {args[0] for relation, args in facts if relation == "nx_values"}
    members = {args[0]: args[1] for relation, args in facts if relation == "nx_value_members"}
    links = {args[0]: args[1] for relation, args in facts if relation == "nx_member_values"}
    observed = {args[0]: args[1] for relation, args in facts if relation == "nx_observation_values"}
    roots = {observed[obs] for obs, _, kind, _, _, _ in observations if kind == "config-path" and obs in observed}
    if results[0][1] == "complete" and not roots:
        raise Refusal("projection-incomplete", "complete config-value projection lacks an observed selected-root value")
    edges = {}
    for member, parent in members.items():
        if member in links:
            edges.setdefault(parent, []).append(links[member])
    if max(len(values), len(members), len(observations), results[0][3]) > request["maxNodes"]:
        raise Refusal("node-limit", "projection node limit exceeded")
    # Topological traversal bounds shared DAGs without exponentially revisiting paths.
    incoming = dict.fromkeys(values, 0)
    for children in edges.values():
        for child in children:
            incoming[child] += 1
    depths = dict.fromkeys(roots, 0)
    pending = [value for value in roots if incoming[value] == 0]
    reached = set()
    while pending:
        value = pending.pop()
        if depths[value] > request["maxDepth"]:
            raise Refusal("depth-limit", "projection exceeds depth limit")
        reached.add(value)
        for child in edges.get(value, []):
            depths[child] = max(depths.get(child, 0), depths[value] + 1)
            incoming[child] -= 1
            if incoming[child] == 0:
                pending.append(child)
    if reached != values or any(parent not in reached for parent in members.values()):
        raise ValueError("detached or cyclic projection values or members")
    if results[0][1] not in ("complete", "partial") and values:
        raise ValueError("unsuccessful transaction contains successful values")
    return facts, results[0][1]


def publish(directory, name, facts):
    """A staging file cannot be selected by the importer before validation/rename."""
    descriptor, temporary = tempfile.mkstemp(prefix=".projection-", dir=directory)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(trap(facts))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, directory / (name + ".trap"))
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def supervise(manifest, bindings, trap_dir, *, strict=False, nix="nix"):
    directory = Path(trap_dir)
    directory.mkdir(parents=True, exist_ok=True)
    # An invocation's run is unique; request fingerprints below remain source/policy based.
    run = abi.key("run", [str(time.time_ns())])
    schema_hash = hashlib.sha256((Path(__file__).resolve().parents[2] / "schema/contract.json").read_bytes()).hexdigest()
    extractor_hash = hashlib.sha256(Path(__file__).read_bytes() + Path(__file__).with_name("protocol.py").read_bytes()).hexdigest()
    facts = [["nx_runs", [run, schema_hash, extractor_hash, "not-requested", "not-admitted", "not-admitted"]],
             ["nx_phases", [run, "syntax", "not-requested", "evaluation supervisor only"]]]
    incomplete = False
    published = set()

    def diagnostic(code, message, target=None, request=None):
        # Diagnostics are bounded separately from producer output and exact-text limits.
        message = str(message).encode("utf-8", errors="replace")[:4096].decode("utf-8", errors="ignore")
        key = abi.key("diagnostic", [run, str(len(facts))])
        facts.append(["nx_diagnostics", [key, run, code, message]])
        if target:
            facts.append(["nx_diagnostic_targets", [key, target]])
        if request:
            facts.append(["nx_diagnostic_requests", [key, request]])

    try:
        validate(manifest, "target-manifest.json")
    except Exception as error:
        # JSON Schema exceptions carry user-supplied documents: keep only the category.
        diagnostic("manifest-invalid", type(error).__name__)
        facts.extend([["nx_phases", [run, "discovery", "failed", "manifest-invalid"]],
                      ["nx_phases", [run, "evaluation", "failed", "discovery failed"]]])
        incomplete = True
    else:
        fingerprints = [target["fingerprint"] for target in manifest["targets"].values()]
        facts[0][1][-2:] = [digest(sorted(pin[field] for pin in fingerprints))
                           for field in ("modelVersion", "sourceSnapshotHash")]
        facts.append(["nx_phases", [run, "discovery", "complete", ""]])
        for name, target in manifest["targets"].items():
            fingerprint = target["fingerprint"]
            components = [fingerprint["evaluatorVersion"], fingerprint["libVersion"], target["adapterVersion"],
                          fingerprint["modelVersion"], target["argumentDescription"]["hash"],
                          fingerprint["sourceSnapshotHash"], fingerprint["policyHash"], target["system"]]
            identity = abi.key("target", components + [name])
            context = abi.key("context", [identity, "root"])
            target_row = [identity, run, name, target["adapter"], target["system"],
                          fingerprint["evaluatorVersion"], fingerprint["libVersion"],
                          digest(target["inputIdentities"]), fingerprint["policyHash"], "complete"]
            facts.extend([["nx_targets", target_row], ["nx_contexts", [context, identity, "root", "[]"]],
                          ["nx_capabilities", [identity, "projection-transport", "supported", "bounded F2 producer"]],
                          ["nx_capabilities", [identity, "module-adapter", "unavailable", "E2 not implemented"]]])
            states = []
            for ordinal, request in enumerate(target["requests"]):
                req = abi.key("request", [identity, context, abi.canonical(request), str(ordinal)])
                facts.append(["nx_requests", [req, identity, context, request["domain"], abi.path(request["path"]), request["facet"],
                              *[request[key] for key in ("maxDepth", "maxNodes", "maxBytes", "maxSeconds", "maxMemoryMiB")]]])
                try:
                    if (request["domain"], request["facet"]) != ("config", "value") or "selected-value" not in target["observationModes"]:
                        raise Refusal("request-unsupported", "E1 supports only selected config-value projections", "blocked")
                    args = target["argumentDescription"]
                    binding = bindings[target["evaluation"]["reference"]]
                    job = {"identities": {"context": context, "request": req, "run": run, "target": identity},
                           "moduleArguments": bindings[args["moduleArgumentsRef"]], "request": request,
                           "specialArguments": bindings[args["specialArgumentsRef"]], "target": target}
                    abi.canonical(job)
                    deadline = time.monotonic() + request["maxSeconds"]
                    with tempfile.TemporaryDirectory(prefix="nixql-e1-") as temporary:
                        scratch = Path(temporary)
                        env = {"HOME": temporary, "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
                               "NIX_CONF_DIR": temporary, "NIX_USER_CONF_FILES": "", "PATH": os.defpath,
                               "TMPDIR": temporary, "XDG_CACHE_HOME": temporary, "XDG_CONFIG_HOME": temporary}
                        if set(binding) == {"command"}:
                            argv = binding["command"]
                        elif set(binding) == {"expression"}:
                            argv = nix_command(nix, binding, job, request, scratch, deadline, env)
                        else:
                            raise Refusal("binding-unsupported", "binding must explicitly select a producer", "blocked")
                        result = json.loads(execute(argv, job, request, scratch, deadline, env))
                    produced, state = projection_rows(result, job, facts)
                    publish(directory, digest([run, req]), produced)
                    facts.extend(produced)
                    published.update(map(id, produced))
                    if state != "complete":
                        diagnostic("projection-incomplete", "producer returned " + state, identity, req)
                except Exception as error:
                    state = getattr(error, "state", "blocked" if isinstance(error, (KeyError, FileNotFoundError)) else "failed")
                    code = getattr(error, "code", "projection-invalid")
                    # F2 exact-text formats delegate to F1; retain its refusal code.
                    if str(getattr(error, "cause", error)) == "text-field-too-large":
                        code = "text-field-too-large"
                    facts.append(["nx_request_results", [req, state, code, 0]])
                    diagnostic(code, str(error), identity, req)
                states.append(state)
            if any(state != "complete" for state in states):
                target_row[-1] = "partial" if any(state in ("complete", "partial") for state in states) else ("blocked" if all(state == "blocked" for state in states) else "failed")
                incomplete = True
        facts.append(["nx_phases", [run, "evaluation", "partial" if incomplete else "complete", "incomplete requests" if incomplete else ""]])
    packet = envelope(facts)
    publish(directory, digest([run, "supervisor"]), [row for row in facts if id(row) not in published])
    if strict and incomplete:
        raise ExtractionFailed(packet)
    return packet
