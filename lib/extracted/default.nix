{pkgs}: let
  inherit (pkgs) lib;
  facts = import ./facts.nix {inherit lib;};
  host = pkgs.stdenv.hostPlatform.system;
  # The per-system drift check's `passthru.regenerate`; regenCommand runs it.
  regenerateName = name: "${name}-regenerate-extracted";
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
    perSystem = builtins.isAttrs extracted && !lib.isDerivation extracted;
    # A host-run extractor builds only on its own system; a static one may
    # supply every system's raw from this host. Each is compared, and
    # regenerated, at the same derived paths.
    targets =
      map (system: let
        present = builtins.filter (candidate: builtins.hasAttr "${candidate}.json" (builtins.readDir committed)) (import ../../config/systems.nix);
        measured =
          if builtins.pathExists (committed + "/${system}.json")
          then system
          else if builtins.length present == 1
          then builtins.head present
          else throw "mkDriftCheck: ${toString committed} expected ${system}.json or exactly one raw named by config/systems.nix";
      in {
        committed = committed + "/${measured}.json";
        extracted = extracted.${system};
        sidecar = "${sidecar}/${measured}.json";
      })
      (builtins.filter (system: extracted ? ${system} && extracted.${system}.system == host) (import ../../config/systems.nix));
    compare = {
      committed,
      extracted,
      # Single mode stops here; per-system records it and fails at the end.
      onDrift,
      # The operator's commands, as `echo` lines to stderr.
      regenerate,
      sidecar,
    }: ''
      if ! "$jq" -e -n --slurpfile a ${extracted} --slurpfile b ${committed} '$a == $b' > /dev/null; then
        echo "FAIL: ${name} sidecar (${sidecar}) is out of sync with its extraction sources." >&2
        "$jq" -S . ${committed} > committed.json
        "$jq" -S . ${extracted} > extracted.json
        ${pkgs.diffutils}/bin/diff -u committed.json extracted.json >&2 || :
        echo "Regenerate from the repository root:" >&2
        ${regenerate}
        ${onDrift}
      fi
    '';
    comparisons =
      if perSystem
      then ''
        drifted=0
        ${lib.concatMapStrings (target:
          compare (target
            // {
              onDrift = "drifted=1";
              regenerate = "echo '  nix run .#checks.${host}.${name}-extracted.passthru.regenerate' >&2";
            }))
        targets}if [ "$drifted" -eq 1 ]; then exit 1; fi
      ''
      else
        compare {
          inherit committed extracted sidecar;
          onDrift = "exit 1";
          regenerate = ''
            echo '  extracted="$(nix build --no-link --print-out-paths .#checks.${host}.${name}-extracted.passthru.extracted)"' >&2
            echo '  cp "$extracted" ${sidecar}' >&2
            echo '  nix fmt -- ${sidecar}' >&2
          '';
        };
    # Copies each buildable extraction over the same sidecar it compared,
    # including the sole committed raw of an owner measured once.
    regenerate = import ../strict-shell-application.nix pkgs {
      name = regenerateName name;
      text =
        lib.concatMapStrings (target: ''
          echo "${name}: regenerating ${target.sidecar}"
          ${pkgs.coreutils}/bin/cp ${target.extracted} ${target.sidecar}
          ${pkgs.coreutils}/bin/chmod 644 ${target.sidecar}
          ${pkgs.nix}/bin/nix fmt -- ${target.sidecar}
          echo "${name}: wrote ${target.sidecar}"
        '')
        targets;
    };
  in {
    "${name}-extracted" =
      pkgs.runCommand "${name}-extracted-drift" {
        passthru = {inherit extracted;} // lib.optionalAttrs perSystem {inherit regenerate;};
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
in {
  inherit (facts) children expect get getFor load merge;
  inherit (import ./reconcile.nix {inherit lib;}) reconcile;
  inherit mkDriftCheck;
  index = facts.index pkgs;

  mkOwnerCheck = {
    dir,
    name,
    needs ? [],
    package,
    results ? {},
  }: let
    ownerFacts = facts.load {inherit dir;};
  in
    mkDriftCheck {
      committed = dir;
      extracted.${host} = package.passthru.extracted;
      inherit name;
      # `facts` and `consumers` are this builder's own surfaces; an owner's
      # `results` (reconcile output) may not shadow them, or a supplied
      # `facts.failures = []` would silence every merge failure.
      results =
        lib.throwIf (results ? consumers || results ? facts)
        "mkOwnerCheck ${name}: results.facts and results.consumers are reserved; pass reconcile results under their own surface names"
        (results
          // {
            consumers = facts.expect {
              inherit (ownerFacts) aggregate;
              consumer = name;
              inherit needs;
            };
            facts = ownerFacts;
          });
      sidecar = "packages/${name}/extracted";
    };

  # An owner's update script regenerates its per-system raws on this host;
  # the script echoes each path as mkExtractRegen does.
  regenCommand = {name}: ''
    regenerate=$(${pkgs.nix}/bin/nix build --no-link --print-out-paths \
      ".#checks.${host}.${name}-extracted.passthru.regenerate")
    "$regenerate/bin/${regenerateName name}"
  '';
}
