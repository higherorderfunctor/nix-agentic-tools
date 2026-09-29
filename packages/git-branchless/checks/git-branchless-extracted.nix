# The committed packages/git-branchless/extracted.json, and the extractor
# that produces it.
#
#   git-branchless-extracted          drift: the committed sidecar equals a
#                                     fresh extraction of the pinned, patched
#                                     source. Blocking, because
#                                     lib/settings.nix generates the typed
#                                     options from the committed file.
#   git-branchless-extractor-guards   the extractor fails closed: every
#                                     mutant in extractor-mutants.nix either
#                                     trips the guards it names or moves the
#                                     output exactly as it says.
#   git-branchless-extracted-binary   every literal key the census reports is
#                                     a string in the built binary, so the
#                                     census cannot describe a key the release
#                                     does not contain.
#
# The drift check catches STALENESS only. The update pipeline regenerates the
# sidecar inside the bump PR (`passthru.regenerateExtracted`), so a wrong
# extraction would be committed as the new truth and this goes green over
# it. Correctness is the job of the extractor's own guards, which fail the
# `passthru.extracted` build this check depends on, and of the mutants.
{
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (pkgs.stdenv.hostPlatform) system;
    package = self.packages.${system}.git-branchless;
    inherit (package.passthru) extracted patchedSource;
    committed = ../extracted.json;
    extractFile = name: ../extract + "/${name}";
    jq = "${pkgs.jq}/bin/jq";
  in {
    git-branchless-extracted = pkgs.runCommand "git-branchless-extracted-drift" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      if ${jq} -e -n --slurpfile a ${extracted} --slurpfile b ${committed} '$a == $b' >/dev/null; then
        echo "ok — packages/git-branchless/extracted.json matches the patched git-branchless source" >"$out"
      else
        echo "FAIL: packages/git-branchless/extracted.json is out of sync with the patched git-branchless source." >&2
        diff <(${jq} -S . ${committed}) <(${jq} -S . ${extracted}) >&2 || :
        echo "" >&2
        echo "Regenerate from the repository root:" >&2
        echo '  "$(nix build --no-link --print-out-paths .#git-branchless.passthru.regenerateExtracted)"' >&2
        exit 1
      fi
    '';

    git-branchless-extractor-guards =
      pkgs.runCommand "git-branchless-extractor-guards" {
        nativeBuildInputs = [pkgs.ast-grep pkgs.python3];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        python3 ${extractFile "mutate.py"} \
          --annotations ${extractFile "annotations.json"} \
          --ast-grep ${pkgs.ast-grep}/bin/ast-grep \
          --baseline ${extracted} \
          --extractor ${extractFile "extract.py"} \
          --mutants ${pkgs.writeText "git-branchless-extractor-mutants.json" (builtins.toJSON (import ./extractor-mutants.nix))} \
          --rules ${extractFile "rules/config.yml"} \
          --src ${patchedSource} >"$out"
      '';

    git-branchless-extracted-binary = pkgs.runCommand "git-branchless-extracted-binary" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      binary=${package}/bin/git-branchless
      # A `<name>` family is a format string; its literal prefix survives.
      missing=""
      while IFS= read -r key; do
        grep -aqF -- "$key" "$binary" || missing="$missing $key"
      done < <(${jq} -r '.settings | keys[] | sub("<name>$"; "")' ${committed})
      if [ -n "$missing" ]; then
        echo "FAIL: packages/git-branchless/extracted.json names keys absent from $binary:$missing" >&2
        exit 1
      fi
      ${jq} -r '.settings | keys | "ok — all \(length) extracted keys are strings in the binary"' ${committed} >"$out"
    '';
  };
}
