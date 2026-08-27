# The generation-time runner for the typed `.sgra` option surface: strictdoc's
# own interpreter, importable, with the extractor's entry point passed as
# argv[1].
#
# ── Why this is here and not in an overlay ───────────────────────────────────
#
# It used to live in `overlays/dev-tools/strictdoc-grammar-extract.nix`, which
# read dev/fragments/overlays/overlay-pattern.md's "an overlay must not import
# build sources from `packages/`" as forbidding the milestone's layout and
# shipped a wrapped environment instead. RULED by the operator 2026-08-26
# (MECH-GRAMMAR-EXTRACT-SOURCE-BOUNDARY): the invariant was read the wrong way
# round. An overlay is the faithful CONVERSION of an upstream package; wrapping
# — environment, flags, configuration — belongs to the module that consumes it.
# This runner converts nothing, so the overlay was DELETED rather than thinned,
# and `pkgs.ai.devTools.strictdoc-grammar-extract` no longer exists. Do not
# reintroduce it: `overlays/dev-tools/strictdoc.nix` is the conversion, this is
# the wrap, and the split is the point.
#
# The wrap is a factory rather than inline module code because it has two
# consumers that are not each other: `../modules/devenv`, which puts it in the
# dev shell, and the four `checks/strictdoc-grammar-*.nix`, which run the same
# entry points in a derivation with no module system in sight. flake.nix builds
# it ONCE for those checks; nothing else may build a second copy, or a session
# and CI stop running the same interpreter.
#
# ── The environment ──────────────────────────────────────────────────────────
#
# The interpreter is UPSTREAM'S OWN VIRTUAL ENVIRONMENT, reached through the
# shebang of `${strictdoc}/bin/strictdoc`, and that indirection is forced.
# overlays/dev-tools/strictdoc.nix re-exports upstream's flake package, which is
# `mkApplication` over a uv2nix venv: `$out` holds that one script and nothing
# else, so there is no `site-packages` to put on PYTHONPATH and no list of
# dependency derivations to hand to `withPackages` (`dependencies` on that
# package is a uv2nix name → extras ATTRSET). The venv the shebang names is a
# build input of the application, not a flake output, so the script is the only
# handle on it. It carries strictdoc plus everything `uv.lock` pins, textx and
# arpeggio included — neither of which is on a plain interpreter's path.
#
# `ast_grep_py` is the one thing that venv does not carry, and it is spliced
# onto PYTHONPATH, because the normalizer matches over the faithful surface's
# Nix source in process. That splice is a version coupling: an extension module
# built for `pkgs.python3` is only importable by upstream's interpreter while
# the two agree on the Python MINOR version. MEASURED 2026-08-27 against this
# repository's pin — 3.14.7 against upstream's 3.14.6, `import ast_grep_py`
# clean and the grammar builder returning the same `4adcdb05…` grammar the
# implementation brief records. The install check below is what makes a future
# divergence fail here rather than in a session.
#
# `alejandra` is deliberately absent. `emit_nix.format_nix` shells out to it and
# downgrades a miss to a WARNING, passing the source through unformatted, so a
# caller that diffs against a formatted file has to name it itself — see the
# header of checks/strictdoc-grammar-surface-current.nix.
#
# ── One consequence of moving the wrap out of the overlay ────────────────────
#
# Build inputs now come from the CONSUMER's `pkgs` rather than from the
# overlay's isolated `ourPkgs`, which is what wrapping in a module means. That
# is only safe here because the part that has to agree with upstream's venv —
# the interpreter — is upstream's own, and the one spliced import is guarded by
# the install check.
{
  lib,
  pkgs,
  strictdoc,
}: let
  inherit (pkgs) ast-grep makeWrapper python3 stdenvNoCC;

  astGrepPy = pkgs.python3Packages.ast-grep-py;
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

    meta = {
      description = "Generation-time runner for StrictDoc's typed .sgra Nix surface";
      mainProgram = "strictdoc-grammar-extract";
      license = lib.licenses.unlicense;
      platforms = lib.platforms.unix;
    };
  }
