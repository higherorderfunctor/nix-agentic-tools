{
  lib,
  pkgs,
  ...
}: let
  mkLintedCheck = import ../../lib/mk-linted-check.nix {inherit pkgs;};
  source = lib.cleanSource ../..;

  # Every spelling of a nullable type the scan must see. Each is a separate
  # declaration the pattern has to match, so a narrowed pattern fails the
  # check here instead of passing a real declaration in the corpus.
  spellings = [
    "type = lib.types.nullOr lib.types.str;"
    "type = types.nullOr types.str;"
    "type = with lib.types; nullOr str;"
    "type = with lib; types.nullOr types.str;"
    "type = with types; nullOr str;"
    "type = nullOr str;"
  ];
  samples = pkgs.writeText "text-source-nullable-spellings.nix" (lib.concatMapStrings (type: ''
      text = mkOption {
        ${type}
      };
    '')
    spellings);
in {
  checks.text-source-no-nullable-options = mkLintedCheck "text-source-no-nullable-options" {
    runtimeInputs = [pkgs.ripgrep];
    text = ''
      # `type =`, any `with <scope>;` prefixes, then `nullOr` bare or qualified.
      pattern='(?ms)^\s*(?:options\.)?(text|source)\s*=\s*(?:lib\.)?mkOption\s*\{(?:(?!^\s*\};).)*?type\s*=\s*(?:with\s+[\w.]+\s*;\s*)*(?:\w+\.)*nullOr\b'

      sample_status=0
      sample_count="$(rg --count-matches --multiline -P "$pattern" ${samples})" || sample_status=$?
      if [[ "$sample_status" -ne 0 || "$sample_count" -ne ${toString (builtins.length spellings)} ]]; then
        printf '%s\n' \
          'the nullable text/source pattern no longer matches every spelling in ${samples}' >&2
        exit 1
      fi

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
