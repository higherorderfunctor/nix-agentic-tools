{pkgs}: let
  python = pkgs.python3.withPackages (ps: [ps.json5 ps.pyyaml]);
  script = pkgs.replaceVars ./unique-map-keys.py {
    nixInstantiate = "${pkgs.nix}/bin/nix-instantiate";
  };
  validator = import ../../lib/strict-shell-application.nix pkgs {
    name = "unique-map-keys";
    text = ''
      if [ "$#" -eq 0 ]; then
        echo "usage: unique-map-keys FILE..." >&2
        exit 2
      fi
      exec ${python}/bin/python ${script} "$@"
    '';
  };
in {
  package = validator;
}
