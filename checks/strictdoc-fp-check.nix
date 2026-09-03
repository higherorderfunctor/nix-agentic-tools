# checks/strictdoc-fp-check.nix -- SLICE-FP-DETECTOR's CI gate
# (docs/plans/strictdoc-tooling/slice-fp-detector.sdoc). Exports the whole design
# graph and runs dev/scripts/fp-check.py over it, failing the build on any
# drifted, unbacked, or deleted-parent PARENT_FP entry.
#
# The clean output directory is load-bearing, not incidental: `strictdoc
# export` caches under its output dir, and a broken input can exit 1 then
# exit 0 on re-run against a warm one -- see the sdoc skill's gotcha list.
# `runCommand` gives every build its own fresh $TMPDIR, so there is no warm
# cache to produce that false green with.
#
# `pkgs.ai.devTools.strictdoc`, not `pkgs.strictdoc`: the overlay re-exports
# upstream's own flake, which tracks main, so the design system is measured
# against what upstream ships rather than against whichever version the nixpkgs
# pin carries (SLICE-STRICTDOC-OVERLAY).
#
# `sdocTsEnv` is the tree-sitter parser registry
# (packages/strictdoc-grammar/lib/tsGrammars.nix), spliced into the build
# environment because this gate runs strictdoc's OWN CLI rather than the
# `strictdoc-grammar-extract` wrapper that carries the same values as
# `--set-default`. Since strictdoc_config.py turned
# REQUIREMENT_TO_SOURCE_TRACEABILITY on, an export without them dies on the
# first `.nix` source file it reads. Same splice devenv.nix carries for a
# hand-run export.
{
  pkgs,
  sdocTsEnv,
  self,
}:
pkgs.runCommand "strictdoc-fp-check" (sdocTsEnv
  // {
    nativeBuildInputs = [pkgs.ai.devTools.strictdoc pkgs.python3];
  }) ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  export HOME="$TMPDIR"
  strictdoc export ${self} --formats=json --output-dir "$TMPDIR/output"
  python3 ${self}/dev/scripts/fp-check.py "$TMPDIR/output/json/index.json" | tee "$out"
''
