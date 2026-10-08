{pkgs}: let
  inherit (pkgs) lib;
in {
  inherit (import ./reconcile.nix {inherit lib;}) reconcile;

  mkDriftCheck = {
    committed,
    extracted,
    name,
    results ? {},
    # The sidecar's repository path, as a string, for messages only. A path
    # derived from `committed` would move with its owner, and
    # checks.facet-owner-relocation requires the check not to.
    sidecar,
  }: let
    failures = lib.concatMap (surface: surface.failures) (builtins.attrValues results);
  in {
    "${name}-extracted" =
      pkgs.runCommand "${name}-extracted-drift" {
        passthru = {inherit extracted;};
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        jq="${pkgs.jq}/bin/jq"
        if ! "$jq" -e -n --slurpfile a ${extracted} --slurpfile b ${committed} '$a == $b' > /dev/null; then
          echo "FAIL: ${name} sidecar (${sidecar}) is out of sync with its extraction sources." >&2
          "$jq" -S . ${committed} > committed.json
          "$jq" -S . ${extracted} > extracted.json
          ${pkgs.diffutils}/bin/diff -u committed.json extracted.json >&2 || :
          echo "Regenerate from the repository root:" >&2
          echo '  extracted="$(nix build --no-link --print-out-paths .#checks.${pkgs.stdenv.hostPlatform.system}.${name}-extracted.passthru.extracted)"' >&2
          echo '  cp "$extracted" ${sidecar}' >&2
          echo '  nix fmt -- ${sidecar}' >&2
          exit 1
        fi
        ${lib.optionalString (failures != []) ''
          echo 'FAIL: ${name} extraction rows need attention:' >&2
          "$jq" . ${pkgs.writeText "${name}-extracted-failures.json" (builtins.toJSON failures)} >&2
          exit 1
        ''}
        echo "ok — ${name} sidecar matches the fresh extraction" > "$out"
      '';
  };
}
