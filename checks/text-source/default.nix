{
  lib,
  pkgs,
  ...
}: let
  mkLintedCheck = import ../../lib/mk-linted-check.nix {inherit pkgs;};
  source = lib.cleanSource ../..;

  # Representative spellings of nullable types the scan must see. Each is a
  # separate declaration the pattern has to match, so a narrowed pattern fails
  # the check here instead of passing a real declaration in the corpus. Put
  # another field before type so the scan cannot assume type is the first field.
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
    # Requiring a qualifier would let a bare nullable type through.
    bare = nullableText "nullOr str";
    # Requiring a bare option name would miss dotted options.source declarations.
    qualified-source = {
      match = "source";
      text = declaration "options.source = lib.mkOption" "lib.types.nullOr lib.types.path";
    };
    # Recognizing only bare or fully qualified types would miss the intermediate spelling.
    types-qualified = nullableText "types.nullOr types.str";
    # A with clause need not import types directly: the nullOr after it can still be qualified.
    with-lib = nullableText "with lib; types.nullOr types.str";
    # A single-identifier scope matcher would miss the dotted lib.types import.
    with-lib-types = nullableText "with lib.types; nullOr str";
    # Requiring an explicit lib reference in the scope would miss an imported types alias.
    with-types = nullableText "with types; nullOr str";

    # Allowed declarations: scanning across the closing brace would make the
    # nullable neighbor look like the type of the non-nullable text option.
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
        local name="$1" file="$2" expected="$3" actual expected_status=0 status=0
        if [[ -z "$expected" ]]; then
          expected_status=1
        fi
        actual="$(scan --only-matching --replace "\$1" "$file")" || status=$?
        if [[ "$actual" != "$expected" ]] || (( status != expected_status )); then
          printf '%s: expected nullable option %s (status %s), got %s (status %s)\n' \
            "$name" "''${expected:-<none>}" "$expected_status" "''${actual:-<none>}" "$status" >&2
          exit 1
        fi
      }

      ${sampleChecks}

      # This file is excluded below because it owns the canonical nullable source leaf.
      # Require just that match so the exclusion cannot hide a second nullable declaration.
      checkSample 'lib/ai/types.nix (shared text-source constructor)' ${source}/lib/ai/types.nix source

      # Samples can pass even when a real declaration bypasses the shared type.
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
