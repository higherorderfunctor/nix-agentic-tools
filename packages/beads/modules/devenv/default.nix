{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.beads;
  lifecycle = import ../../lib/mkLifecycle.nix {inherit cfg lib pkgs;};
  lifecycleExe = lib.getExe' lifecycle.lifecycle "beads-lifecycle";
in {
  imports = [(import ../options.nix {inherit lib;})];

  config = lib.mkMerge [
    {
      services.beads.package = lib.mkDefault pkgs.ai.devTools.beads;

      assertions = [
        {
          assertion = !cfg.enable || cfg.issuePrefix != null;
          message = "services.beads.issuePrefix is required when services.beads.enable is true";
        }
        {
          assertion = !cfg.enable || cfg.ledgerUrl != null;
          message = "services.beads.ledgerUrl is required when services.beads.enable is true";
        }
        {
          assertion = !cfg.enable || cfg.package ? dolt;
          message = "services.beads.package must expose its exact Dolt runtime as passthru.dolt";
        }
        {
          assertion =
            !cfg.enable
            || cfg.issuePrefix == null
            || builtins.match "^[a-z][a-z0-9_-]*$" cfg.issuePrefix != null;
          message = "services.beads.issuePrefix must match ^[a-z][a-z0-9_-]*$";
        }
        {
          assertion =
            !cfg.enable
            || cfg.ledgerUrl == null
            || (
              cfg.ledgerUrl
              != ""
              && !lib.hasInfix "\n" cfg.ledgerUrl
              && !lib.hasInfix "\r" cfg.ledgerUrl
              && builtins.match "^[Hh][Tt][Tt][Pp][Ss]?://[^/@]+@.*$" cfg.ledgerUrl == null
              && builtins.match "^[A-Za-z][A-Za-z0-9+.-]*://[^/@]*:[^/@]+@.*$" cfg.ledgerUrl == null
            );
          message = "services.beads.ledgerUrl must be nonempty, single-line, and contain no embedded HTTP userinfo or URL password";
        }
      ];
    }
    (lib.mkIf cfg.enable {
      packages = [lifecycle.package];

      processes = {
        beads-publisher.exec = "${lifecycleExe} publisher";
        beads-server.exec = "${lifecycleExe} server";
      };

      tasks = {
        "beads:bootstrap" = {
          description = "Initialize or verify the contained Beads ledger";
          exec = "${lifecycleExe} bootstrap";
        };
        "beads:checkpoint" = {
          description = "Validate the clean local ledger checkpoint";
          exec = "${lifecycleExe} checkpoint";
        };
        "beads:diagnostics" = {
          description = "Inspect Beads lifecycle versions and invariants";
          exec = "${lifecycleExe} diagnostics";
        };
        "beads:prepare" = {
          description = "Materialize contained runtime state without publishing";
          before = ["devenv:enterShell"];
          exec = "${lifecycleExe} prepare";
        };
        "beads:status" = {
          description = "Report contained Beads lifecycle status";
          exec = "${lifecycleExe} status";
        };
      };
    })
  ];
}
