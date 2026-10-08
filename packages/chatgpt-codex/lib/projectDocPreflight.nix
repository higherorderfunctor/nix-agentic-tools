pkgs: let
  extracted = builtins.fromJSON (builtins.readFile ../extracted.json);
  flags = pkgs.lib.listToAttrs (pkgs.lib.concatMap (command:
    pkgs.lib.concatMap (flag:
      map (name: {
        inherit name;
        value = flag.valueName != null;
      })
      flag.names)
    command.flags) (builtins.attrValues extracted.cli.commands));
  schema = pkgs.writeText "codex-preflight-flag-values.json" (builtins.toJSON flags);
  resolver = import ./effectiveProjectDocMaxBytes.nix pkgs;
in
  import ../../../lib/strict-shell-application.nix pkgs {
    name = "codex-project-doc-preflight";
    text = ''
      exec ${pkgs.coreutils}/bin/timeout --kill-after=0.1 1 ${pkgs.python3}/bin/python3 ${./projectDocPreflight.py} ${pkgs.lib.getExe resolver} ${schema} "$@"
    '';
  }
