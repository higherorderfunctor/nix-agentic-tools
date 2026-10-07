{pkgs}: let
  inherit (pkgs) lib;
  # The eval consumes the current rows: a temporary file prevents truncating
  # that input before Nix snapshots the working tree.
  mkRowsRegen = {
    name,
    path,
  }: ''
    extracted_rows_tmp="$(${pkgs.coreutils}/bin/mktemp)" && ${pkgs.nix}/bin/nix eval --json ".#checks.${pkgs.stdenv.hostPlatform.system}.${name}-extracted.passthru.rows" > "$extracted_rows_tmp" && ${pkgs.coreutils}/bin/mv "$extracted_rows_tmp" ${lib.escapeShellArg path} && ${pkgs.nix}/bin/nix fmt -- ${lib.escapeShellArg path}
  '';
in {
  inherit mkRowsRegen;
  inherit (import ./reconcile.nix {inherit lib;}) reconcile withAdded;

  mkDriftCheck = {
    committed,
    extracted,
    name,
    results ? {},
    rows ? null,
    # The sidecar's repository path, as a string, for messages only. A path
    # derived from `committed` would move with its owner, and
    # checks.facet-owner-relocation requires the check not to.
    sidecar,
  }: let
    failures = lib.concatMap (surface: surface.failures) (builtins.attrValues results);
    printRowsCommand = lib.optionalString (rows != null) "echo ${lib.escapeShellArg ("  "
      + mkRowsRegen {
        inherit name;
        inherit (rows) path;
      })} >&2";
  in {
    "${name}-extracted" =
      pkgs.runCommand "${name}-extracted-drift" {
        passthru = {inherit extracted;} // lib.optionalAttrs (rows != null) {rows = rows.value;};
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
          ${printRowsCommand}
          exit 1
        fi
        ${lib.optionalString (failures != []) ''
          echo 'FAIL: ${name} extraction rows need attention:' >&2
          "$jq" . ${pkgs.writeText "${name}-extracted-failures.json" (builtins.toJSON failures)} >&2
          ${lib.optionalString (lib.any (failure: failure.kind == "unrecorded") failures) printRowsCommand}
          exit 1
        ''}
        echo "ok — ${name} sidecar matches the fresh extraction" > "$out"
      '';
  };
}
