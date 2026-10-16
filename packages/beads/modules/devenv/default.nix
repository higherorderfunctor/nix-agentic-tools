{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.beads;
  hasDolt = cfg.package ? dolt && lib.isDerivation cfg.package.dolt;
  issuePrefixValid =
    cfg.issuePrefix
    != null
    && builtins.match "^[a-z][a-z0-9_-]*$" cfg.issuePrefix != null;
  ledgerUrlValid =
    cfg.ledgerUrl
    != null
    && cfg.ledgerUrl != ""
    && !lib.hasInfix "\n" cfg.ledgerUrl
    && !lib.hasInfix "\r" cfg.ledgerUrl
    && builtins.match "^[Hh][Tt][Tt][Pp][Ss]?://[^/@]+@.*$" cfg.ledgerUrl == null
    && builtins.match "^[A-Za-z][A-Za-z0-9+.-]*://[^/@]*:[^/@]+@.*$" cfg.ledgerUrl == null;
  lifecycleReady = hasDolt && issuePrefixValid && ledgerUrlValid;
  lifecycle =
    if lifecycleReady
    then import ../../lib/mkLifecycle.nix {inherit cfg lib pkgs;}
    else null;
  lifecycleExe =
    if lifecycleReady
    then lib.getExe' lifecycle.lifecycle "beads-lifecycle"
    else null;
in {
  imports = [
    (import ../options.nix {inherit lib;})
    (import ../../../ai-module/lib/runtime.nix {
      enabled = cfg.enable;
      name = "beads";
    })
  ];

  config = lib.mkMerge [
    {
      services.beads.package = lib.mkDefault config.ai.internal.packages.devTools.beads;

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
          assertion = !cfg.enable || hasDolt;
          message = "services.beads.package must expose its exact Dolt derivation as passthru.dolt";
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
    (lib.mkIf (cfg.enable && lifecycleReady) {
      packages = [lifecycle.package];

      processes = {
        beads-publisher.exec = "${lifecycleExe} publisher";
        beads-server.exec = "${lifecycleExe} server";
      };

      ai.beads.activation2.beads-prepare.command = "${lifecycleExe} prepare";

      # Manual lifecycle entry points remain native tasks.
      tasks =
        lib.mapAttrs (task: description: {
          inherit description;
          exec = "${lifecycleExe} ${lib.removePrefix "beads:" task}";
        }) {
          "beads:bootstrap" = "Initialize or verify the contained Beads ledger";
          "beads:checkpoint" = "Validate the clean local ledger checkpoint";
          "beads:diagnostics" = "Inspect Beads lifecycle versions and invariants";
          "beads:status" = "Report contained Beads lifecycle status";
        };
    })
  ];
}
