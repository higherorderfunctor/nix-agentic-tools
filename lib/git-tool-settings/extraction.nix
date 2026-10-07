# Build and check a git tool's config-key census: the Nix half of
# lib/git-tool-settings, shared by every owner with an `extract/` directory
# (git-branchless, git-absorb, git-revise).
#
#   patchedSource {name; package}   the package's own src + patches +
#                                   postPatch, unpacked under stdenvNoCC, so
#                                   the census reads exactly the tree that is
#                                   built and never pulls a toolchain in
#   extracted {name; source; extractDir; tools ? []}
#                                   runs `<extractDir>/extract.py` over the
#                                   source, with `tools` on PATH; any guard
#                                   fails the build
#   checks {name; package; sidecar; committed; extractDir; mutants; installed}
#                                   the three checks below, keyed by name
#
# The package carries `passthru.{patchedSource,extracted}`. passthru is not a
# derivation input, so neither moves the package's store path, and the drift
# check and the update pipeline's regeneration read the same derivation.
{pkgs}: let
  inherit (import ../extracted {inherit pkgs;}) mkDriftCheck;
  jq = "${pkgs.jq}/bin/jq";

  # One interpreter for every extractor: tree-sitter-rust for the Rust
  # tools, docutils for git-revise's man page; git-revise's own parser is
  # imported from the source tree it reads.
  python = pkgs.python3.withPackages (ps: [ps.docutils ps.tree-sitter ps.tree-sitter-rust]);
  shared = ./.;

  strict = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
  '';
in {
  inherit python;

  patchedSource = {
    name,
    package,
  }:
    pkgs.srcOnly {
      inherit (package) src;
      name = "${name}-patched";
      patches = package.patches or [];
      postPatch = package.postPatch or "";
      stdenv = pkgs.stdenvNoCC;
    };

  extracted = {
    name,
    source,
    extractDir,
    tools ? [],
  }:
    pkgs.runCommand "${name}-extracted.json" {
      nativeBuildInputs = [python] ++ tools;
      PYTHONPATH = shared;
    } ''
      ${strict}
      python3 ${extractDir + "/extract.py"} \
        --annotations ${extractDir + "/annotations.json"} \
        --out "$out" \
        --src ${source}
    '';

  # `sidecar` is the repository path in messages, `committed` the file.
  # `installed` is the file or directory in the built package that must hold
  # every extracted key as a string.
  checks = {
    name,
    package,
    sidecar,
    committed,
    extractDir,
    mutants,
    installed,
  }: let
    inherit (package.passthru) extracted patchedSource;
    # The extraction's own tools (asciidoc for git-absorb's man page) are
    # what the mutants need too.
    inherit (extracted) nativeBuildInputs;
  in {
    # Drift: the committed sidecar equals a fresh extraction. Staleness
    # only; the update pipeline commits whatever the extractor says, so
    # correctness rests on the guards and the mutants.
    "${name}-extracted" = mkDriftCheck {
      inherit committed extracted name;
    };

    # The extractor fails closed: every mutant trips the guards it names or
    # moves the output exactly as it says.
    "${name}-extractor-guards" =
      pkgs.runCommand "${name}-extractor-guards" {
        inherit nativeBuildInputs;
        PYTHONPATH = shared;
      } ''
        ${strict}
        python3 ${shared + "/mutate.py"} \
          --annotations ${extractDir + "/annotations.json"} \
          --baseline ${extracted} \
          --extractor ${extractDir + "/extract.py"} \
          --mutants ${pkgs.writeText "${name}-extractor-mutants.json" (builtins.toJSON mutants)} \
          --src ${patchedSource} >"$out"
      '';

    # Every key the census reports (a `<name>` family by its literal prefix)
    # is a string in the built package, so the census cannot describe a key
    # the release does not contain.
    "${name}-extracted-binary" = pkgs.runCommand "${name}-extracted-binary" {} ''
      ${strict}
      target=${package}/${installed}
      missing=""
      while IFS= read -r key; do
        grep -raqF -- "$key" "$target" || missing="$missing $key"
      done < <(${jq} -r '.settings | keys[] | sub("<name>$"; "")' ${committed})
      if [ -n "$missing" ]; then
        echo "FAIL: ${sidecar} names keys absent from $target:$missing" >&2
        exit 1
      fi
      ${jq} -r '.settings | keys | "ok — all \(length) extracted keys are strings in ${installed}"' ${committed} >"$out"
    '';
  };
}
