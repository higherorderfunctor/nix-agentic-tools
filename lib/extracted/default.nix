{pkgs}: let
  inherit (pkgs) lib;
in {
  inherit (import ./reconcile.nix {inherit lib;}) reconcile;

  mkDriftCheck = {
    # A path, or per system (the facts contract's "Drift") the owner's
    # `extracted/` directory; `<system>.json` is derived under it.
    committed,
    # A path or derivation, or `{ "<system>" = derivation; }`.
    extracted,
    name,
    results ? {},
    # The sidecar's repository path, as a string, for messages only. A path
    # derived from `committed` would move with its owner, and
    # checks.facet-owner-relocation requires the check not to. Per system it
    # names the directory, like `committed`.
    sidecar,
  }: let
    failures = lib.concatMap (surface: surface.failures) (builtins.attrValues results);
    host = pkgs.stdenv.hostPlatform.system;
    perSystem = builtins.isAttrs extracted && !lib.isDerivation extracted;
    # A host-run extractor builds only on its own system; a static one may
    # supply every system's raw from this host.
    buildable = builtins.filter (system: extracted ? ${system} && extracted.${system}.system == host) (import ../../config/systems.nix);
    compare = {
      committed,
      extracted,
      sidecar,
      attr,
      # Single mode stops here; per-system records it and fails at the end.
      onDrift,
    }: ''
      if ! "$jq" -e -n --slurpfile a ${extracted} --slurpfile b ${committed} '$a == $b' > /dev/null; then
        echo "FAIL: ${name} sidecar (${sidecar}) is out of sync with its extraction sources." >&2
        "$jq" -S . ${committed} > committed.json
        "$jq" -S . ${extracted} > extracted.json
        ${pkgs.diffutils}/bin/diff -u committed.json extracted.json >&2 || :
        echo "Regenerate from the repository root:" >&2
        echo '  extracted="$(nix build --no-link --print-out-paths .#checks.${host}.${name}-extracted.passthru.${attr})"' >&2
        echo '  cp "$extracted" ${sidecar}' >&2
        echo '  nix fmt -- ${sidecar}' >&2
        ${onDrift}
      fi
    '';
    comparisons =
      if perSystem
      then ''
        drifted=0
        ${lib.concatMapStrings (system:
          compare {
            committed = committed + "/${system}.json";
            extracted = extracted.${system};
            sidecar = "${sidecar}/${system}.json";
            attr = "extracted.${system}";
            onDrift = "drifted=1";
          })
        buildable}if [ "$drifted" -eq 1 ]; then exit 1; fi
      ''
      else
        compare {
          inherit committed extracted sidecar;
          attr = "extracted";
          onDrift = "exit 1";
        };
  in {
    "${name}-extracted" =
      pkgs.runCommand "${name}-extracted-drift" {
        passthru = {inherit extracted;};
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        jq="${pkgs.jq}/bin/jq"
        ${comparisons}${lib.optionalString (failures != []) ''
          echo 'FAIL: ${name} extraction rows need attention:' >&2
          "$jq" . ${pkgs.writeText "${name}-extracted-failures.json" (builtins.toJSON failures)} >&2
          exit 1
        ''}
        echo "ok — ${name} sidecar matches the fresh extraction" > "$out"
      '';
  };
}
