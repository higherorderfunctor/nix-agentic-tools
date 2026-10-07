{pkgs}: let
  inherit (import ../packaging.nix) ciAttr;
in {
  mkDriftCheck = {
    committed,
    extracted,
    name,
  }:
    pkgs.runCommand "${name}-extracted-drift" {
      passthru = {inherit extracted;};
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      jq="${pkgs.jq}/bin/jq"
      if "$jq" -e -n --slurpfile a ${extracted} --slurpfile b ${committed} '$a == $b' > /dev/null; then
        echo "ok — ${name} sidecar matches the fresh extraction" > "$out"
      else
        echo "FAIL: ${name} sidecar (${builtins.baseNameOf committed}) is out of sync with its extraction sources." >&2
        "$jq" -S . ${committed} > committed.json
        "$jq" -S . ${extracted} > extracted.json
        ${pkgs.diffutils}/bin/diff -u committed.json extracted.json >&2 || :
        echo "Regenerate from the repository root:" >&2
        echo '  "$(nix build --no-link --print-out-paths .#${ciAttr {
        attr = name;
        inherit pkgs;
      }}.passthru.regenerateExtracted)"' >&2
        exit 1
      fi
    '';
}
