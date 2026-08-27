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
# The interpreter is UPSTREAM'S OWN VIRTUAL ENVIRONMENT, reached through the
# shebang of `${strictdoc}/bin/strictdoc`, and that indirection is forced.
# ./strictdoc.nix now re-exports upstream's flake package, which is
# `mkApplication` over a uv2nix venv: `$out` holds that one script and nothing
# else, so there is no `site-packages` to put on PYTHONPATH and no list of
# dependency derivations to hand to `withPackages` (`dependencies` on that
# package is a uv2nix name → extras ATTRSET). The venv the shebang names is a
# build input of the application, not a flake output, so the script is the only
# handle on it. It carries strictdoc plus everything `uv.lock` pins, textx and
# arpeggio included — neither of which is on a plain interpreter's path.
#
# `ast_grep_py` is the one thing that venv does not carry, and it arrives on
# PYTHONPATH from `ourPkgs` (ast-grep is on PATH from there too), because the
# normalizer matches over the faithful surface's Nix source in process. That
# splice is a version coupling: an extension module built for `ourPkgs.python3`
# is only importable by upstream's interpreter while the two agree on the
# Python MINOR version. MEASURED 2026-08-27 — ourPkgs 3.14.7 against upstream's
# 3.14.6, `import ast_grep_py` clean and the grammar builder returning the same
# `4adcdb05…` grammar the brief records. The install check below is what makes
# a future divergence fail here rather than in a session.
#
# Cache-hit parity: every build input either routes through `ourPkgs` (this
# repo's nixpkgs pin) or comes from upstream's own locked flake, never
# `final`/`prev`. See dev/fragments/overlays/cache-hit-parity.md.
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

  astGrepPy = ourPkgs.python3Packages.ast-grep-py;
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

      # Upstream's application is a single script whose shebang names the venv
      # interpreter. Read it rather than guessing a path, and fail loudly if the
      # shape ever changes — a wrapper, a launcher, anything but an interpreter
      # — because the alternative is a wrapper that builds and cannot import.
      venvPython=$(sed -n '1s|^#!||p' "${strictdoc}/bin/strictdoc")
      if [ ! -x "$venvPython" ]; then
        echo "strictdoc-grammar-extract: ${strictdoc}/bin/strictdoc no longer" \
             "shebangs an executable interpreter (got '$venvPython')" >&2
        exit 1
      fi

      makeWrapper "$venvPython" "$out/bin/strictdoc-grammar-extract" \
        --prefix PYTHONPATH : "${astGrepPy}/${python3.sitePackages}" \
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
