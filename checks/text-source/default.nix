{
  lib,
  pkgs,
  ...
}: let
  mkLintedCheck = import ../../lib/mk-linted-check.nix {inherit pkgs;};
  source = lib.cleanSource ../..;

  # Every spelling of a nullable type the scan must see. Each is a separate
  # declaration the pattern has to match, so a narrowed pattern fails the
  # check here instead of passing a real declaration in the corpus. Put another
  # field before type so the scan cannot assume type is the first field.
  # Indent the header and closer as in the corpus; both are scan boundaries.
  declaration = header: type:
    "      ${header} {\n"
    + "        description = \"Sample option.\";\n"
    + "        type = ${type};\n"
    + "      };\n";
  textDeclaration = declaration "text = mkOption";
  nullableText = type: {
    match = "text";
    text = textDeclaration type;
  };
  samples = {
    # Forbidden declarations.
    bare = nullableText "nullOr str";
    lib-qualified = nullableText "lib.types.nullOr lib.types.str";
    qualified-source = {
      match = "source";
      text = declaration "options.source = lib.mkOption" "lib.types.nullOr lib.types.path";
    };
    types-qualified = nullableText "types.nullOr types.str";
    with-lib = nullableText "with lib; types.nullOr types.str";
    with-lib-types = nullableText "with lib.types; nullOr str";
    with-types = nullableText "with types; nullOr str";

    # Allowed declarations: a neighboring nullable option is not a nullable text/source.
    non-nullable = {
      match = "";
      text = textDeclaration "lib.types.lines" + declaration "other = mkOption" "lib.types.nullOr lib.types.str";
    };
  };
  sampleChecks = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: sample: ''
      checkSample ${lib.escapeShellArg name} ${pkgs.writeText "${name}.nix" sample.text} ${lib.escapeShellArg sample.match}
    '')
    samples);
in {
  checks.text-source-no-nullable-options = mkLintedCheck "text-source-no-nullable-options" {
    runtimeInputs = [pkgs.ripgrep];
    text = ''
      # `type =`, any `with <scope>;` prefixes, then `nullOr` bare or qualified.
      pattern='(?ms)^\s*(?:options\.)?(text|source)\s*=\s*(?:lib\.)?mkOption\s*\{(?:(?!^\s*\};).)*?type\s*=\s*(?:with\s+[\w.]+\s*;\s*)*(?:\w+\.)*nullOr\b'

      scan() {
        rg --multiline -P "$pattern" "$@"
      }

      checkSample() {
        local name="$1" file="$2" expected="$3" actual status=0
        actual="$(scan --only-matching --replace "\$1" "$file")" || status=$?
        if (( status > 1 )); then
          printf '%s: nullable-option scan failed with status %s\n' "$name" "$status" >&2
          exit "$status"
        fi
        if [[ "$actual" != "$expected" ]]; then
          printf '%s: expected nullable option %s, got %s\n' \
            "$name" "''${expected:-<none>}" "''${actual:-<none>}" >&2
          exit 1
        fi
      }

      ${sampleChecks}

      # This file is excluded below because it owns the canonical nullable source leaf.
      checkSample 'lib/ai/types.nix (shared text-source constructor)' ${source}/lib/ai/types.nix source

      status=0
      matches="$(scan --glob '*.nix' --glob '!**/lib/ai/types.nix' --line-number ${source})" || status=$?

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
