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

        failures = [f for f, c in patched_ours.items() if c != 0]
        assert not failures, f"patched grammar must parse our own corpus with zero errors: {failures}"

        regressions = [
            f
            for f in strictdoc_docs
            if patched_strictdoc[f] > baseline_strictdoc[f]
        ]
        assert not regressions, f"patched grammar regressed on strictdoc's own docs: {regressions}"

        print("\nok — no regressions, our corpus fully clean")


    if __name__ == "__main__":
        main()
  '';

  manifest = pkgs.writeText "strictdoc-corpus-manifest.json" (builtins.toJSON {
    patched = "${patched}/parser";
    baseline = "${baseline}/parser";
    ours = ourCorpus;
    strictdocDocs = strictdocCorpus;
  });

  pythonWithTreeSitter = pkgs.python3.withPackages (ps: [ps.tree-sitter]);
in
  pkgs.runCommand "strictdoc-grammar-corpus" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    ${pythonWithTreeSitter}/bin/python3 ${countScript} ${manifest} | tee "$out"
  ''
