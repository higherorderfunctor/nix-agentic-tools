{pkgs}: {
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
        echo '  extracted="$(nix build --no-link --print-out-paths .#checks.${pkgs.stdenv.hostPlatform.system}.${name}-extracted.passthru.extracted)"' >&2
        echo '  cp "$extracted" ${pkgs.lib.removePrefix "${toString ../..}/" (toString committed)}' >&2
        echo '  nix fmt' >&2
        exit 1
      fi
    '';
}
