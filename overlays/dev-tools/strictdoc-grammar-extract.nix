# strictdoc-grammar-extract — the generation-time runner for the typed `.sgra`
# option surface (SLICE-GRAMMAR-FROM-NIX, docs/plans/strictdoc-tooling/
# 03-executable-rules.sdoc; design of record in
# packages/strictdoc-grammar/docs/implementation-brief.md).
#
# ── SCAFFOLD, and it is a PARTIAL one. Read this before extending it. ────────
#
# What this package ships is the ENVIRONMENT the extractor needs, wrapped as one
# binary. What it does NOT ship is the extractor's own entry points, because
# wiring them in would require this file to take
# `packages/strictdoc-grammar/extract/` as its `src`, and
# dev/fragments/overlays/overlay-pattern.md forbids exactly that edge:
#
#   "Repo-local implementation sources consumed by an overlay derivation belong
#    beside that derivation under `overlays/`, even when a package module is
#    their only runtime consumer. An overlay must not import build sources from
#    `packages/`: that outbound edge prevents lifting the overlay tree as a
#    clean directory move."
#
# The operator's layout instruction for this milestone puts the three Python
# entry points under `packages/strictdoc-grammar/extract/`. The two cannot both
# hold, so this file takes the option that changes nothing: the wrapper is a
# python launcher and the entry point is its first argument.
#
#   strictdoc-grammar-extract packages/strictdoc-grammar/extract/extract.py \
#     --output packages/strictdoc-grammar/lib/faithful.nix
#
# Resolving the conflict is one small edit either way — relocate the sources
# under `overlays/dev-tools/strictdoc-grammar-extract/` and add `src` + an
# `--add-flags` line, or record an exemption to the invariant and point `src` at
# `packages/`. That decision is the operator's, and it is logged in
# docs/plans/strictdoc-tooling/99-backlog.sdoc.
#
# ── The environment, which IS settled ────────────────────────────────────────
#
# * The interpreter carries strictdoc's own dependency closure. `dependencies`
#   is THIS repository's overridden list (reqif pinned to 0.1.0 by
#   ./strictdoc.nix), and `withPackages` takes the transitive closure of what it
#   is given, so textx and arpeggio — neither of which is on a plain
#   interpreter's path — resolve along with everything else strictdoc imports.
# * strictdoc itself is not a library in nixpkgs (`python3Packages.strictdoc`
#   does not exist — MEASURED against this repository's pin), so its own
#   site-packages goes on PYTHONPATH by hand. This replaces the brief's
#   `sed -n '3p' .strictdoc-wrapped` recipe, which is the right move for an
#   interactive shell and the wrong one for a derivation.
# * ast-grep is on PATH and `ast_grep_py` is in the interpreter, because the
#   normalizer matches over the faithful surface's Nix source in process.
#
# Cache-hit parity: every build input routes through `ourPkgs` (this repo's
# nixpkgs pin), never `final`/`prev`. See dev/fragments/overlays/cache-hit-parity.md.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) ast-grep lib makeWrapper python3 stdenvNoCC;

  # The same derivation `pkgs.ai.devTools.strictdoc` resolves to, so the surface
  # is extracted from the release a session and the checks actually run.
  strictdoc = import ./strictdoc.nix {inherit inputs final;};

  pythonEnv = python3.withPackages (ps: strictdoc.dependencies ++ [ps.ast-grep-py]);
in
  stdenvNoCC.mkDerivation {
    pname = "strictdoc-grammar-extract";
    version = "0.1.0";

    # Nothing to fetch, unpack, configure or build: this derivation is one
    # wrapper over an interpreter that is already built.
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;

    nativeBuildInputs = [makeWrapper];

    installPhase = ''
      runHook preInstall
      makeWrapper ${pythonEnv}/bin/python3 "$out/bin/strictdoc-grammar-extract" \
        --prefix PYTHONPATH : "${strictdoc}/${python3.sitePackages}" \
        --suffix PATH : "${lib.makeBinPath [ast-grep]}"
      runHook postInstall
    '';

    # The whole point of the package asserted at build time: strictdoc's grammar
    # builder imports, and so do the two matcher libraries. Every one of these
    # is invisible to a plain interpreter, so a broken PYTHONPATH fails here
    # rather than in a session.
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      "$out/bin/strictdoc-grammar-extract" -c '
      import ast_grep_py, arpeggio, textx
      from strictdoc.backend.sdoc.grammar.grammar_builder import SDocGrammarBuilder
      assert SDocGrammarBuilder.create_grammar_grammar()
      '
      runHook postInstallCheck
    '';

    passthru.updateTargetExempt = "repository-local generation tool with no upstream release";

    meta = {
      description = "Generation-time runner for StrictDoc's typed .sgra Nix surface";
      mainProgram = "strictdoc-grammar-extract";
      license = lib.licenses.unlicense;
      platforms = lib.platforms.unix;
    };
  }
