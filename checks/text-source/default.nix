{
  lib,
  pkgs,
  ...
}: let
  mkLintedCheck = import ../../lib/mk-linted-check.nix {inherit pkgs;};
  source = lib.cleanSource ../..;
in {
  checks.text-source-no-nullable-options = mkLintedCheck "text-source-no-nullable-options" {
    runtimeInputs = [pkgs.ripgrep];
    text = ''
      pattern='(?ms)^\s*(?:options\.)?(text|source)\s*=\s*(?:lib\.)?mkOption\s*\{(?:(?!^\s*\};).)*?type\s*=\s*(?:lib\.)?types\.nullOr\b'
      canonical_status=0
      canonical_count="$(rg --count-matches --multiline -P "$pattern" ${source}/lib/ai/types.nix)" || canonical_status=$?
      if [[ "$canonical_status" -ne 0 || "$canonical_count" -ne 1 ]]; then
        printf '%s\n' \
          'lib/ai/types.nix must contain exactly the canonical nullable source leaf inside the shared text-source constructor' >&2
        exit 1
      fi

      status=0
      matches="$(rg --glob '*.nix' --glob '!**/lib/ai/types.nix' --line-number --multiline -P "$pattern" ${source})" || status=$?

      if [[ "$status" -eq 0 ]]; then
        printf '%s\n' \
          'nullable text/source options are forbidden; use the shared { enable, text, source } type:' \
          "$matches" >&2
        exit 1
      fi
      if [[ "$status" -ne 1 ]]; then
        printf 'text-source nullable-option scan failed with status %s\n' "$status" >&2
        exit "$status"
      fi
    '';
  };
}
