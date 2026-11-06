{pkgs}: let
  python = pkgs.python3.withPackages (ps: [ps.json5 ps.pyyaml]);
  script = pkgs.replaceVars ./unique-map-keys.py {
    nixInstantiate = "${pkgs.nix}/bin/nix-instantiate";
  };
in
  import ../../lib/strict-shell-application.nix pkgs {
    name = "unique-map-keys";
    text = ''exec ${python}/bin/python ${script} "$@"'';
  }
