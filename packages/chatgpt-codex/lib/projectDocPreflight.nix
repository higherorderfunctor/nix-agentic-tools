pkgs: let
  inherit (import ../../../lib/extracted/facts.nix {inherit (pkgs) lib;}) children load;
  codexFacts = load {dir = ../extracted;};
  flags = pkgs.lib.listToAttrs (pkgs.lib.concatMap (commandFlags:
    pkgs.lib.concatMap (flag:
      map (name: {
        inherit name;
        value = flag.valueName != null;
      })
      flag.names)
    commandFlags) (builtins.attrValues (children codexFacts.aggregate "cli.commands.<name>.flags")));
  schema = pkgs.writeText "codex-preflight-flag-values.json" (builtins.toJSON flags);
  resolver = import ./effectiveProjectDocMaxBytes.nix pkgs;
  notices = map (notice: pkgs.lib.getExe (import notice pkgs)) [./projectTrustNotice.nix ./permissionLayersNotice.nix];
in
  import ../../../lib/strict-shell-application.nix pkgs {
    name = "codex-project-doc-preflight";
    text = ''
      exec ${pkgs.python3}/bin/python3 ${./projectDocPreflight.py} ${pkgs.lib.getExe resolver} ${schema} ${pkgs.lib.escapeShellArgs notices} "$@"
    '';
  }
