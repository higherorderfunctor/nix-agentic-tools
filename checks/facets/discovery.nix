{pkgs, ...}: let
  # Build-time probes can inspect the actual failure diagnostic and create
  # non-regular entry points without publishing malformed workspace concerns.
  probe = pkgs.writeText "facet-check-discovery-probe.nix" ''
    {root}: let
      pkgs = import ${pkgs.path} {system = ${builtins.toJSON pkgs.stdenv.hostPlatform.system};};
      inherit (pkgs) lib;
      discover = import ${../../lib}/testing/discover.nix {inherit lib;};
      world = (import ${../../lib}/facets.nix {inherit lib;}).realizeChecks {
        context = {inherit lib pkgs;};
        index.owners = [];
        rootModules = discover root;
      };
    in builtins.attrNames world.checks
  '';
in {
  checks.facet-check-discovery = pkgs.runCommandLocal "facet-check-discovery" {nativeBuildInputs = [pkgs.nix];} ''
    export NIX_STATE_DIR="$TMPDIR/nix-state"
    mkdir -p "$NIX_STATE_DIR/profiles/per-user/$USER" empty non-regular/broken/default.nix valid/active
    cp ${./discovery-fixtures}/active/default.nix valid/active/default.nix
    cp ${./discovery-fixtures}/ignored.nix valid/ignored.nix
    cp -R ${./discovery-fixtures}/private valid/active/private

    evaluate() {
      nix-instantiate --eval --strict --json ${probe} --argstr root "$1"
    }

    # These sentinels throw if file sidecars or nested fixture modules are
    # imported, so a successful positive control also proves discovery depth.
    test "$(evaluate "$PWD/valid")" = '["discovered"]'
    test "$(evaluate "$PWD/empty")" = '[]'

    reject() {
      local root="$1"
      local directory="$2"
      if evaluate "$root" >probe.stdout 2>probe.stderr; then
        echo "check discovery unexpectedly accepted $directory" >&2
        return 1
      fi
      grep -F "check discovery error: directory '$directory' must contain a regular default.nix check module" probe.stderr
    }

    reject ${./discovery-fixtures} ${./discovery-fixtures}/private
    reject "$PWD/non-regular" "$PWD/non-regular/broken"
    touch "$out"
  '';
}
