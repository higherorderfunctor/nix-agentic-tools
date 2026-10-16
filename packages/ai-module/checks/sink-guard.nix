# Scan production libraries and modules; exact non-writer lines are measured
# exceptions, never whole-file exemptions. Negative fixtures cover every owner.
{
  lib,
  pkgs,
  ...
}: let
  nonWriters = {
    "lib/ai/app/generatedFiles.nix" = ["files = lib.mapAttrs (path: entry:"];
    "lib/ai/app/sharedAgentsMd.nix" = ["files = lib.mkMerge [" "files = lib.mkOption {visible = false;};"];
    "lib/options-doc.nix" = ["enterTest = lib.mkOption {" "files = lib.mkOption {" "home = {" "tasks = lib.mkOption {"];
    "lib/testing/factory-harness.nix" = ["files = lib.mkOption {" "home = {"];
    "lib/testing/module-harness.nix" = ["enterTest = lib.mkOption {" "files = config.ai.files;" "files = lib.mkOption {" "home = {" "tasks = lib.mkOption {"];
    "packages/beads/modules/devenv/default.nix" = ["tasks ="];
    "packages/semble/modules/options.nix" = [''files = ["config.json" "model.safetensors" "modules.json" "tokenizer.json"];''];
  };
  exceptions = pkgs.writeText "native-sink-non-writers" (lib.concatStringsSep "\n" (lib.concatLists (lib.mapAttrsToList (path: map (line: "${path}:${line}")) nonWriters)) + "\n");
  negatives = ["lib/probe.nix"] ++ map (owner: "packages/${owner}/modules/probe.nix") ["beads" "git" "git-branchless" "glab" "mcp-services" "semble"];
  script = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    work="$PWD"
    scan() (
      cd "$1"
      anchored='^[[:space:]]*(home\.file|home\.activation|files|tasks|enterTest)([."[]|[[:space:]]*=)'
      nested='^[[:space:]]*home[[:space:]]*=[[:space:]]*\{'
      ${pkgs.findutils}/bin/find lib packages -type f -name '*.nix' \
        \( -path 'lib/*' -o -path 'packages/*/lib/*' -o -path 'packages/*/modules/*' \) \
        -not -path 'packages/ai-module/*' -print0 \
        | ${pkgs.coreutils}/bin/sort -z > "$work/corpus"
      ${pkgs.coreutils}/bin/test -s "$work/corpus"
      : > "$work/actual"
      while IFS= read -r -d $'\0' path; do
        rc=0
        ${pkgs.gnugrep}/bin/grep -nHE -e "$anchored" -e "$nested" "$path" > "$work/hits" || rc=$?
        [ "$rc" -le 1 ] || exit "$rc"
        while IFS= read -r hit; do
          code="''${hit#*:}"
          code="''${code#*:}"
          code="''${code#"''${code%%[![:space:]]*}"}"
          rc=0
          ${pkgs.gnugrep}/bin/grep -Fxq "$path:$code" ${exceptions} || rc=$?
          [ "$rc" -le 1 ] || exit "$rc"
          if [ "$rc" -eq 1 ]; then
            printf '%s\n' "$hit" >> "$work/actual"
          fi
        done < "$work/hits"
      done < "$work/corpus"
      if [ -s "$work/actual" ]; then
        echo "ai-module: route direct native sink writes through ai.<owner>.files or ai.<owner>.activation." >&2
        ${pkgs.coreutils}/bin/cat "$work/actual" >&2
        exit 1
      fi
    )
    scan "$src"
    echo "PASS: libraries and owner modules contain no direct native sink writes"
    # Each forbidden form must fail in every newly covered location. A fixture
    # goes through the same corpus discovery, exception filter and failure path.
    for path in ${lib.escapeShellArgs negatives}; do
      for sink in home.file home.activation files tasks enterTest; do
        fixture="$work/negative"
        ${pkgs.coreutils}/bin/mkdir -p "$fixture/lib" "$fixture/packages" "$fixture/''${path%/*}"
        printf '  %s.probe = {};\n' "$sink" > "$fixture/$path"
        if scan "$fixture" 2> "$work/negative-error"; then
          echo "FAIL: accepted direct $sink write in $path" >&2
          exit 1
        fi
        ${pkgs.gnugrep}/bin/grep -Fq "$path:1:" "$work/negative-error"
        ${pkgs.coreutils}/bin/rm "$fixture/$path"
      done
    done
    echo "PASS: 35 direct native sink fixtures refused" > "$out"
  '';
in {
  checks.ai-module-no-direct-sink-writes =
    pkgs.runCommandLocal "ai-module-no-direct-sink-writes" {
      src = ../../..;
      passthru = {inherit exceptions script;};
    }
    script;
}
