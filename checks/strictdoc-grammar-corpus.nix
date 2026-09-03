# checks/strictdoc-grammar-corpus.nix — SLICE-SDOC-IN-SEMBLE's corpus/
# regression suite for the patched tree-sitter-strictdoc grammar
# (overlays/generic/tree-sitter-strictdoc.nix). Upstream ships zero tests for
# this grammar, and DEC-GRAMMAR-PATCH-NOT-FORK
# (packages/semble/.sdoc/dec-grammar-patch-not-fork.sdoc) requires one to live in
# this repository as a check rather than in the grammar source.
#
# Builds the grammar TWICE from the identical pinned source — once through
# the overlay's patch (`patched`), once with no patch at all (`baseline`) —
# and parses two corpora with each:
#
#   - "ours": every .sdoc/.sgra file in THIS repository, found by walking the
#     flake's own source, so the corpus grows with the repo automatically.
#   - "strictdoc's own docs": a pinned fetch of strictdoc-project/strictdoc's
#     docs/ directory (Apache-2.0). Fetched at check time only — never
#     vendored into this repo, so there is nothing to keep in sync with a
#     moving upstream and no third-party content committed here.
#
# The gate: `patched` must parse EVERY file in "ours" with zero ERROR/MISSING
# nodes, and must never RAISE the error count on any strictdoc-own-docs file
# relative to `baseline`. strictdoc's own docs are not required to reach
# zero — several fail on pre-existing, unrelated grammar gaps (document-body
# / FREETEXT coverage) this patch never targeted; see the backlog entry this
# SLICE files for that gap. The build prints a before/after table either way.
#
# CONTROLS, because "every file in this repository parses" is a gate a grammar
# that accepted anything at all would also pass — and so would one whose patch
# had silently not taken effect, since `generate = true` without the preBuild
# override ships upstream's committed `src/parser.c` and still exits 0. Two
# synthetic documents travel the same two parsers:
#
#   accept — a File relation carrying EVERY key StrictDoc's own FileEntry
#     production admits (FORMAT, VALUE, PATH, ELEMENT, ID, LINE_RANGE,
#     FUNCTION, CLASS, HASH), plus the VALUE+ELEMENT+ID shape this repository
#     writes and the PATH-without-VALUE shape it does not. It must parse clean
#     under `patched` and must NOT under `baseline` — that differential is the
#     only thing here that can tell a live patch from an inert one.
#   reject — the same relation carrying a key StrictDoc has never defined. It
#     must NOT parse. Without it, "teach the grammar the whole key set" is
#     indistinguishable from "let a File relation hold anything".
#
# They are `writeText` rather than committed `.sdoc` fixtures deliberately: a
# real file under the repository root is read by every whole-project
# `strictdoc export`, and the reject control is invalid input by construction
# — the same reason `fixtures/negative/` spells its grammars `.sgra.invalid`.
{
  lib,
  pkgs,
  self,
}: let
  patched = pkgs.ai.generic.tree-sitter-strictdoc;

  # Same pinned source as the overlay (patched.src is the fetch BEFORE
  # patchPhase runs), rebuilt with no patch — the "before" half of the
  # before/after comparison this check reports.
  baseline = pkgs.tree-sitter.buildGrammar {
    language = "strictdoc";
    inherit (patched) version src;
    generate = true;
    preBuild = "tree-sitter generate grammar/grammar.js";
  };

  # Walk the flake's own source for every tracked .sdoc/.sgra file. self is
  # already realized as part of flake evaluation, so this is not IFD — the
  # whole repo source is already local by the time a check evaluates.
  # readDir accepts self.outPath directly (a store-path string); no need for
  # the deprecated builtins.toPath.
  repoRoot = self.outPath;
  walk = dir: rel:
    lib.concatLists (lib.mapAttrsToList (
        name: type: let
          path = dir + "/${name}";
          relPath =
            if rel == ""
            then name
            else "${rel}/${name}";
        in
          if type == "directory"
          then walk path relPath
          else if type == "regular" && (lib.hasSuffix ".sdoc" name || lib.hasSuffix ".sgra" name)
          then [path]
          else []
      )
      (builtins.readDir dir));
  ourCorpus = walk repoRoot "";

  # Pinned, not vendored — see the header. `rev` is real HEAD at the time
  # this check was written, not a tagged release; strictdoc-project/strictdoc
  # ships no meaningful release cadence for its own docs/ directory, and any
  # real commit is an equally reproducible pin.
  strictdocUpstream = pkgs.fetchFromGitHub {
    owner = "strictdoc-project";
    repo = "strictdoc";
    rev = "215cda2ebce0909538ea65c490936d5c68cb768f";
    hash = "sha256-FrtSab0tDQKoe5MQjQ+wpm5/tcYVaS2ggokBAPQAFZM=";
  };
  strictdocCorpus =
    map (name: strictdocUpstream + "/docs/${name}")
    (lib.filter (lib.hasSuffix ".sdoc") (builtins.attrNames (builtins.readDir (strictdocUpstream + "/docs"))));

  # A `.sdoc` is whitespace-significant to the byte, so the controls are built
  # from LINE LISTS rather than an indented Nix string: an interpolated
  # multi-line value inside `''…''` keeps its own indentation while the literal
  # around it is stripped, which is exactly the kind of drift that would make a
  # control fail for a reason it does not name. Only RELATIONS differs between
  # the two; the envelope is written once. The node type and its fields are
  # arbitrary — nothing above RELATIONS is what either control measures.
  controlDocument = name: relations:
    pkgs.writeText "strictdoc-corpus-control-${name}.sdoc"
    (lib.concatStringsSep "\n" (
      [
        "[DOCUMENT]"
        "TITLE: File relation control (${name})"
        ""
        "[MECHANISM]"
        "UID: MECH-FILE-RELATION-CONTROL"
        "TITLE: File relation control"
        "STATEMENT: Synthetic; see checks/strictdoc-grammar-corpus.nix."
        "RELATIONS:"
      ]
      ++ relations
      ++ [""]
    ));

  # Every key, in StrictDoc's order, then the two shapes that matter on their
  # own: VALUE+ELEMENT+ID, which is what this repository writes, and PATH with
  # no VALUE, which upstream admits and the pre-patch rule could not express.
  controlAccept = controlDocument "accept" [
    "- TYPE: File"
    "  ROLE: Implements"
    "  FORMAT: Sourcecode"
    "  VALUE: lib/thing.py"
    "  PATH: lib/thing.py"
    "  ELEMENT: function"
    "  ID: thing.do"
    "  LINE_RANGE: 10, 20"
    "  FUNCTION: do"
    "  CLASS: Thing"
    "  HASH: deadbeef"
    "- TYPE: File"
    "  VALUE: lib/other.nix"
    "  ELEMENT: class"
    "  ID: Other"
    "- TYPE: File"
    "  PATH: lib/third.py"
  ];

  controlReject = controlDocument "reject" [
    "- TYPE: File"
    "  VALUE: lib/thing.py"
    "  SPROCKET: not a StrictDoc FileEntry key"
  ];

  countScript = pkgs.writeText "strictdoc-corpus-count.py" ''
    # cspell:ignore argtypes pythonapi restype
    from __future__ import annotations

    import ctypes
    import json
    import sys
    from pathlib import Path

    from tree_sitter import Language, Parser

    SYMBOL = "tree_sitter_strictdoc"


    def _load_capsule(path: str) -> object:
        library = ctypes.CDLL(path)
        entry_point = getattr(library, SYMBOL)
        entry_point.restype = ctypes.c_void_p
        pointer = entry_point()
        if not pointer:
            raise RuntimeError(f"{path!r}: {SYMBOL}() returned a null language pointer")
        py_capsule_new = ctypes.pythonapi.PyCapsule_New
        py_capsule_new.restype = ctypes.py_object
        py_capsule_new.argtypes = (ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p)
        return py_capsule_new(pointer, b"tree_sitter.Language", None)


    def error_count(node) -> int:
        count = 0
        stack = [node]
        while stack:
            n = stack.pop()
            if n.type in ("ERROR", "MISSING") or n.is_error:
                count += 1
            stack.extend(n.children)
        return count


    def parse_all(parser_path: str, files: list[str]) -> dict[str, int]:
        parser = Parser(Language(_load_capsule(parser_path)))
        return {f: error_count(parser.parse(Path(f).read_bytes()).root_node) for f in files}


    def report(title: str, counts: dict[str, int]) -> None:
        clean = sum(1 for c in counts.values() if c == 0)
        print(f"\n== {title}: {clean}/{len(counts)} clean ==")
        for path, count in sorted(counts.items()):
            status = "OK" if count == 0 else f"FAIL ({count})"
            print(f"  {status:12s} {path}")


    def controls(patched_parser: str, baseline_parser: str, accept: str, reject: str) -> list[str]:
        """The accept/reject pair. Returns the failures, printing every verdict.

        Reported as claims rather than as a counts table: the three do not
        share an expectation, and a table whose OK column means the opposite
        thing on one row is how a control quietly stops being read.
        """
        patched_counts = parse_all(patched_parser, [accept, reject])
        baseline_counts = parse_all(baseline_parser, [accept])

        claims = [
            (
                "every StrictDoc FileEntry key parses under the patched grammar",
                patched_counts[accept] == 0,
                f"{accept}: {patched_counts[accept]} error node(s) under the PATCHED grammar",
            ),
            (
                "...and does NOT under the unpatched baseline, so the patch is live",
                baseline_counts[accept] != 0,
                f"{accept}: parsed clean under the BASELINE grammar too, so this "
                "control cannot tell a live patch from an inert one",
            ),
            (
                "a key StrictDoc never defined is still rejected",
                patched_counts[reject] != 0,
                f"{reject}: parsed clean under the PATCHED grammar, so a File "
                "relation now accepts any key at all",
            ),
        ]

        print("\n== controls ==")
        failures = []
        for title, ok, why in claims:
            status = "OK" if ok else "FAIL"
            print(f"  {status:12s} {title}")
            if not ok:
                failures.append(why)
        return failures


    def main() -> None:
        manifest = json.loads(Path(sys.argv[1]).read_text())
        patched_parser = manifest["patched"]
        baseline_parser = manifest["baseline"]
        ours = manifest["ours"]
        strictdoc_docs = manifest["strictdocDocs"]

        patched_ours = parse_all(patched_parser, ours)
        baseline_ours = parse_all(baseline_parser, ours)
        patched_strictdoc = parse_all(patched_parser, strictdoc_docs)
        baseline_strictdoc = parse_all(baseline_parser, strictdoc_docs)

        report("ours, baseline (unpatched)", baseline_ours)
        report("ours, patched", patched_ours)
        report("strictdoc's own docs, baseline (unpatched)", baseline_strictdoc)
        report("strictdoc's own docs, patched", patched_strictdoc)

        control_failures = controls(
            patched_parser,
            baseline_parser,
            manifest["controlAccept"],
            manifest["controlReject"],
        )
        assert not control_failures, "controls failed: " + "; ".join(control_failures)

        failures = [f for f, c in patched_ours.items() if c != 0]
        assert not failures, f"patched grammar must parse our own corpus with zero errors: {failures}"

        regressions = [
            f
            for f in strictdoc_docs
            if patched_strictdoc[f] > baseline_strictdoc[f]
        ]
        assert not regressions, f"patched grammar regressed on strictdoc's own docs: {regressions}"

        print("\nok — controls hold, no regressions, our corpus fully clean")


    if __name__ == "__main__":
        main()
  '';

  manifest = pkgs.writeText "strictdoc-corpus-manifest.json" (builtins.toJSON {
    patched = "${patched}/parser";
    baseline = "${baseline}/parser";
    ours = ourCorpus;
    strictdocDocs = strictdocCorpus;
    controlAccept = "${controlAccept}";
    controlReject = "${controlReject}";
  });

  pythonWithTreeSitter = pkgs.python3.withPackages (ps: [ps.tree-sitter]);
in
  pkgs.runCommand "strictdoc-grammar-corpus" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    ${pythonWithTreeSitter}/bin/python3 ${countScript} ${manifest} | tee "$out"
  ''
