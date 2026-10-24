"""Serialized, bounded F2 projections with atomic validated F1 publication.

Command bindings are explicitly trusted producer fixtures, not a Nix sandbox.
Real expressions run in pure/restricted Nix against hash-pinned admitted roots.
"""

# cspell:ignore preexec RLIMIT setrlimit setsid unrequested

import hashlib
import json
import os
from collections import defaultdict
from pathlib import Path
import resource
import selectors
import signal
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote

from protocol import abi, envelope, trap, validate
from definitions import source_inventory
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from extract import RunIdentity


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


def nix_command(nix, binding, job, request, directory, deadline, env, invocation=None):
    expression = Path(binding["expression"]).resolve(strict=True)
    roots = [Path(root["path"]).resolve(strict=True) for root in job["target"]["sourceRoots"]]
    root = next((root for root in roots if expression.is_relative_to(root)), None)
    if root is None:
        raise Refusal("source-not-admitted", "expression lies outside the admitted closure", "blocked")
    policy = json.loads((Path(__file__).parents[2] / "models/builtins/policy.json").read_text())
    options = [part for key, value in policy.items() for part in ("--option", key, value)]
    base = [str(nix), *options,
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
        if str(admitted) in job.get("sourcePins", {}):
            abi.require(hash_value == job["sourcePins"][str(admitted)], "mixed-source-snapshot")
        # Match Nix's URL spelling exactly; only this pinned local URI is admitted.
        uris.append("path:" + quote(str(admitted), safe="/") + "?narHash=" + quote(hash_value, safe="/"))
        trees.append("builtins.fetchTree { type = \"path\"; path = " + nix_string(str(admitted)) +
                     "; narHash = " + nix_string(hash_value) + "; }")
    selected = trees[roots.index(root)]
    relative = "/" + expression.relative_to(root).as_posix()
    job_source = "builtins.readFile ((" + trees[-1] + ").outPath + \"/job.json\")"
    imported = "(import ((" + selected + ").outPath + " + nix_string(relative) + "))"
    projection = (invocation(imported, trees[:-1]) if invocation else
                  imported + " { job = builtins.fromJSON (" + job_source + "); }")
    return base + ["eval", "--json", "--offline", "--option", "restrict-eval", "true",
                   "--option", "allowed-uris", " ".join(uris),
                   "--option", "allow-import-from-derivation", "false",
                   "--expr", projection]


def graph_rows(facts, job, results, outer):
    """Module-graph projections: budgets and locality are ours, structure is F1's."""
    request = job["request"]
    context = job["identities"]["context"]
    modules = {args[0]: args for relation, args in facts if relation == "nx_modules"}
    origins = {args[0] for relation, args in facts if relation == "nx_origins"}
    observations = [args for relation, args in facts if relation == "nx_observations"]
    links = {kind: {args[0]: args[1] for relation, args in facts if relation == f"nx_observation_{kind}s"}
             for kind in ("context", "module")}
    for args in modules.values():
        if args[1] != context or args[3] not in origins:
            raise ValueError("projection module escapes the selected context")
    for observation, req, stage, _ in observations:
        local = links["context"].get(observation) == context or links["module"].get(observation) in modules
        if req != job["identities"]["request"] or not local or stage != "pre-apply-metadata":
            raise ValueError("projection observation escapes the selected request")
    if origins != {args[3] for args in modules.values()}:
        raise ValueError("projection contains detached or foreign origins")
    children = defaultdict(list)
    for relation, args in facts:
        if relation == "nx_module_imports":
            children[args[0]].append(args[2])
    frontier = [(args[2], 0) for relation, args in facts if relation == "nx_module_roots"]
    depth = 0
    seen = set()
    while frontier:
        module, level = frontier.pop()
        depth = max(depth, level)
        if module in seen:
            continue
        seen.add(module)
        frontier.extend((child, level + 1) for child in children[module])
    if depth > request["maxDepth"]:
        raise Refusal("depth-limit", "module graph exceeds requested depth")
    envelope(outer + facts)
    if results[0][1] != "complete" and (modules or any(row[3] == "observed" for row in observations)):
        raise ValueError("unsuccessful transaction contains successful metadata")
    if max(len(modules), len(observations), results[0][3]) > request["maxNodes"]:
        raise Refusal("node-limit", "projection node limit exceeded")
    return facts, results[0][1]


def projection_rows(packet, job, outer):
    validate(packet, "observation-protocol.json")
    facts = packet["facts"]
    request = job["request"]
    graph = request.get("domain") == "module-graph"
    permitted = ({"nx_module_imports", "nx_module_roots", "nx_modules", "nx_observation_contexts",
                  "nx_observation_modules", "nx_observations", "nx_origins", "nx_request_results"}
                 if graph else
                 {"nx_candidates", "nx_definition_candidate_priorities", "nx_definition_selections", "nx_observation_candidates", "nx_definition_order", "nx_definitions", "nx_module_lib_bindings", "nx_observation_definitions", "nx_observation_options", "nx_observations", "nx_option_declarations", "nx_option_metadata",
                  "nx_option_priority", "nx_options", "nx_origin_positions",
                  "nx_origins", "nx_request_results"})
    if any(relation not in permitted for relation, _ in facts):
        raise ValueError("producer attempted to overwrite supervisor-owned facts")
    identity = job["identities"]["request"]
    results = [args for relation, args in facts if relation == "nx_request_results"]
    if len(results) != 1 or results[0][0] != identity:
        raise ValueError("projection must return exactly its supplied request result")
    if graph:
        return graph_rows(facts, job, results, outer)
    allowed = {"nx_definitions": ("all-definitions", "definitions", "selection"), "nx_option_declarations": ("declarations",),
               "nx_option_metadata": ("all-definitions", "isDefined", "priority", "selection"), "nx_option_priority": ("all-definitions", "priority", "selection")}
    options = {args[0] for relation, args in facts if relation == "nx_options"}
    for relation, args in facts:
        if relation == "nx_options" and args[1:] != [job["identities"]["context"], abi.path(request["path"])]:
            raise ValueError("projection selected an unauthorized option")
        if relation in allowed and args[1 if relation == "nx_definitions" else 0] not in options:
            raise ValueError("projection metadata escapes the selected option")
        if relation in allowed and request["facet"] not in allowed[relation]:
            raise ValueError("projection emitted unrequested metadata")
    definitions = {args[0] for relation, args in facts if relation == "nx_definitions"}
    for relation, args in facts:
        if relation == "nx_definition_order" and (request["facet"] not in ("all-definitions", "selection") or args[0] not in definitions):
            raise ValueError("projection order escapes selected definitions")
    for relation, args in facts:
        if relation == "nx_module_lib_bindings":
            model = job.get("moduleModel")
            if (request["facet"] not in ("all-definitions", "selection") or results[0][1] not in ("complete", "partial") or args[0] != identity
                    or model is None or args[3:] != [model["libHash"], model["bundleHash"]]
                    or not any([candidate["functionAnchor"], candidate["formalAnchor"]] == args[1:3]
                               for candidate in job.get("moduleBindings", []))):
                raise ValueError("projection library binding lacks authenticated invocation")
    candidates = {args[0] for relation, args in facts if relation == "nx_candidates"}
    if any(relation in ("nx_candidates", "nx_definition_candidate_priorities", "nx_definition_selections", "nx_observation_candidates")
           for relation, _ in facts) and request["facet"] != "all-definitions":
        raise ValueError("projection emitted unrequested candidates")
    if any(args[1] not in options for relation, args in facts if relation == "nx_candidates"):
        raise ValueError("candidate escapes selected option")
    observations = [args for relation, args in facts if relation == "nx_observations"]
    subjects = {kind: {args[0]: args[1] for relation, args in facts if relation == f"nx_observation_{kind}s"}
                for kind in ("candidate", "definition", "option")}
    for observation, req, stage, _ in observations:
        subject_is_local = (subjects["option"].get(observation) in options or
                            subjects["definition"].get(observation) in definitions or
                            subjects["candidate"].get(observation) in candidates)
        if req != identity or not subject_is_local or stage != "pre-apply-metadata":
            raise ValueError("projection observation escapes the selected request")
    origins = {args[0] for relation, args in facts if relation == "nx_origins"}
    referenced = {args[-1] for relation, args in facts if relation in ("nx_definitions", "nx_option_declarations")}
    referenced |= {args[3] for relation, args in facts if relation == "nx_candidates"}
    if origins != referenced or any(args[0] not in origins for relation, args in facts if relation == "nx_origin_positions"):
        raise ValueError("projection contains detached or foreign origins")
    envelope(outer + facts)
    if results[0][1] not in ("complete", "partial") and any(relation in allowed for relation, _ in facts):
        raise ValueError("unsuccessful transaction contains successful metadata")
    observed = {kind: [links[args[0]] for args in observations if args[-1] == "observed" and args[0] in links]
                for kind, links in subjects.items()}
    if results[0][1] == "complete":
        for kind, entities in (("candidate", candidates), ("definition", definitions), ("option", options)):
            if set(observed[kind]) != entities or len(observed[kind]) != len(entities):
                raise Refusal("projection-incomplete", "complete metadata projection lacks exactly one observation per subject")
    witnesses = options
    if request["facet"] in ("isDefined", "priority"):
        relation = "nx_option_metadata" if request["facet"] == "isDefined" else "nx_option_priority"
        witnesses = {args[0] for name, args in facts if name == relation}
    if results[0][1] == "complete" and (not set(observed["option"]).intersection(witnesses) or results[0][3] == 0):
        raise Refusal("projection-incomplete", "complete metadata projection lacks an observed selected-option witness")
    if request["facet"] in ("all-definitions", "selection") and results[0][1] in ("complete", "partial"):
        metadata = {args[0]: args[2] for relation, args in facts if relation == "nx_option_metadata" and args[1] == "isDefined"}
        priorities = {args[0] for relation, args in facts if relation == "nx_option_priority"}
        if set(metadata) != options or any((metadata[option] == "true") != (option in priorities) for option in options):
            raise Refusal("projection-incomplete", "selection lacks a witness for whether the option is defined or its priority")
        if request["maxDepth"] == 0 and (definitions or candidates):
            raise Refusal("depth-limit", "definition records exceed root-only depth")
    records = sum(relation in ("nx_candidates", "nx_options", "nx_definitions", "nx_option_declarations") for relation, _ in facts)
    if max(records, len(observations), results[0][3]) > request["maxNodes"]:
        raise Refusal("node-limit", "projection node limit exceeded")
    return facts, results[0][1]


def check_source(path, expected):
    abi.require(path.is_file(), "source-not-admitted")
    with path.open("rb") as stream:
        abi.require(hashlib.file_digest(stream, "sha256").hexdigest() == expected, "source-snapshot-mismatch")


def admitted_sources(source_files, target):
    """S2 files belong to a target snapshot independently of retained origins."""
    roots = {abi.key("root", [root["logicalName"], root["rootContentIdentity"]]): Path(root["path"]).resolve(strict=True)
             for root in target["sourceRoots"]}
    sources = {}
    for _, (file, root, relative, expected, _) in source_files:
        if root not in roots:
            continue
        original = (roots[root] / relative).resolve(strict=True)
        abi.require(original.is_relative_to(roots[root]), "source-not-admitted")
        check_source(original, expected)
        sources[file] = (original, expected)
    return sources


def library_bindings(anchor_rows, sources, mappings):
    """Identify literal module function/formals from the already authenticated S2 tree."""
    anchors = {row[1][0]: row[1] for row in anchor_rows}
    candidates = []
    paths = {(anchor[1], anchor[5]): anchor for anchor in anchors.values()}
    for formal in anchors.values():
        if formal[4] != "identifier" or formal[1] not in sources:
            continue
        data = sources[formal[1]][0].read_bytes()
        if data[formal[2]:formal[3]] != b"lib":
            continue
        child = abi.json_path(formal[5], True)
        function = paths.get((formal[1], abi.canonical(child[:1])))
        if function is None or not abi.library_formal(anchors, function[0], formal[0]):
            continue
        for copied, files in mappings.items():
            files = [files] if isinstance(files, str) else files
            if files == [function[1]]:
                candidates.append({"functionAnchor": function[0], "formalAnchor": formal[0], "path": copied})
    return candidates


def source_links(produced, sources, mappings, copy_root=None):
    """Caller authenticates S2; we verify mapped copies before linking labels."""
    links = []
    for relation, args in produced:
        if relation != "nx_origins" or args[2] != "source" or args[1] not in mappings:
            continue
        mapped = mappings[args[1]]
        mapped = [mapped] if isinstance(mapped, str) else mapped
        matches = set(mapped).intersection(sources)
        if len(matches) != 1:
            continue
        file = matches.pop()
        original, expected = sources[file]
        copy = Path(args[1])
        if copy_root is not None:
            abi.require(copy.is_relative_to("/nix/store"), "source-not-admitted")
            copy = copy_root / copy.relative_to("/")
        abi.require(copy.is_absolute(), "source-not-admitted")
        for path in (original, copy):
            check_source(path, expected)
        links.append(["nx_origin_files", [args[0], file]])
    return links


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


def supervise(manifest, bindings, trap_dir, *, source_files=(), source_mappings=None, source_anchors=(), strict=False, nix="nix", identity=None):
    directory = Path(trap_dir)
    directory.mkdir(parents=True, exist_ok=True)
    coordinated = identity is not None
    identity = identity or RunIdentity.evaluation(abi, __file__)
    identity_object = identity
    run = identity.row[1][0]
    facts = [identity.row]
    if not coordinated:
        facts.append(["nx_phases", [run, "syntax", "not-requested", "evaluation supervisor only"]])
    source_files = list(source_files)
    abi.require(all(row[0] == "nx_files" for row in source_files), "source admission requires S2 file rows")
    abi.validate(source_files)
    facts.extend(source_files)
    facts.extend(source_anchors)
    source_mappings = source_mappings or {}
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
        duplicate_graph = any(
            sum(request["domain"] == "module-graph" and request["facet"] == "closure" and not request["path"]
                for request in target["requests"]) > 1
            for target in manifest["targets"].values())
        if duplicate_graph:
            # Two graph requests would publish conflicting roots for one context.
            diagnostic("duplicate-graph-request", "context admits at most one module-graph request")
            facts.extend([["nx_phases", [run, "discovery", "failed", "duplicate-graph-request"]],
                          ["nx_phases", [run, "evaluation", "failed", "discovery failed"]]])
            incomplete = True
        else:
            fingerprints = [target["fingerprint"] for target in manifest["targets"].values()]
            if coordinated:
                identity.check_targets(abi, manifest)
            else:
                facts[0][1][-2:] = ["not-requested", digest(sorted(pin["sourceSnapshotHash"] for pin in fingerprints))]
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
                              ["nx_capabilities", [identity, "module-adapter", "supported", "evalModules metadata"]]])
                source_error = None
                try:
                    sources = admitted_sources(source_files, target)
                    admissions = [["nx_target_inputs", [identity, file, "root"]] for file in sources]
                    envelope(facts + admissions)
                    facts.extend(admissions)
                except Exception as error:
                    source_error = error
                module_model = getattr(identity_object, "module_model", None)
                helper_state = ("supported" if module_model and fingerprint["libVersion"] == module_model["libHash"]
                                else "unsupported" if module_model else "unavailable")
                capabilities = ["rename-models"]
                if any(request["facet"] == "selection" for request in target["requests"]):
                    capabilities.insert(0, "module-properties")
                for capability in capabilities:
                    facts.append(["nx_capabilities", [identity, capability, helper_state, "exact-pin module helper models"]])
                if any(request["domain"] == "module-graph" for request in target["requests"]):
                    facts.append(["nx_capabilities", [identity, "module-graph", "supported", ""]])
                if any(request["facet"] == "all-definitions" for request in target["requests"]):
                    facts.append(["nx_capabilities", [identity, "all-definitions", helper_state if coordinated else "supported", ""]])
                states = []
                for ordinal, request in enumerate(target["requests"]):
                    req = abi.key("request", [identity, context, abi.canonical(request), str(ordinal)])
                    facts.append(["nx_requests", [req, identity, context, request["domain"], abi.path(request["path"]), request["facet"],
                                  *[request[key] for key in ("maxDepth", "maxNodes", "maxBytes", "maxSeconds", "maxMemoryMiB")]]])
                    try:
                        if source_error is not None:
                            raise source_error
                        if request["facet"] == "selection" and helper_state != "supported":
                            raise Refusal("module-properties-unavailable", "exact-pin property metadata unavailable", "unsupported")
                        if request["facet"] == "all-definitions" and coordinated and helper_state != "supported":
                            raise Refusal("all-definitions-unavailable", "exact-pin definition inventory unavailable", "unsupported")
                        # F2 rejects a non-closure or non-root module-graph request before
                        # its nx_requests row exists; appending one here would poison F1.
                        if request["domain"] != "module-graph" and request["facet"] not in ("all-definitions", "selection") and request["maxDepth"] != 0:
                            raise Refusal("request-unsupported", "only root metadata projections are supported", "blocked")
                        args = target["argumentDescription"]
                        binding = bindings[target["evaluation"]["reference"]]
                        job = {"identities": {"context": context, "model": identity_object.row[1][4], "request": req, "run": run, "target": identity},
                               "moduleArguments": bindings[args["moduleArgumentsRef"]], "request": request,
                               "specialArguments": bindings[args["specialArgumentsRef"]], "target": target}
                        job["moduleModel"] = module_model
                        job["moduleBindings"] = library_bindings(source_anchors, sources, source_mappings)
                        if request["facet"] == "all-definitions":
                            job["definitionSources"] = source_inventory(source_anchors, sources, source_mappings, module_model, request["path"])
                        if coordinated:
                            job["sourcePins"] = {root["path"]: root["rootContentIdentity"] for root in target["sourceRoots"]}
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
                            links = source_links(produced, sources, source_mappings,
                                                 scratch / "store" if "expression" in binding else None)
                            if time.monotonic() >= deadline:
                                raise Refusal("timeout", "source authentication time-limit exceeded")
                        produced.extend(links)
                        envelope(facts + produced)
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
    publish(directory, digest([run, "supervisor"]), [row for row in facts if id(row) not in published and (not coordinated or row[0] != "nx_runs")])
    if strict and incomplete:
        raise ExtractionFailed(packet)
    return packet
