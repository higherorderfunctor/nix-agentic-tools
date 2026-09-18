# Shared kiro-crew module body. Both backends import this supplying only their
# native effects, so the option tree and every decision made from it are
# identical and parity is structural rather than something a reviewer notices.
#
# The backend hooks are deliberately few — three things genuinely differ:
#
#   installPackages  where an installed package goes (`home.packages` vs
#                    devenv's `packages`).
#   installEnv       how an environment variable reaches the user's processes
#                    (`home.sessionVariables` vs devenv's `env`).
#   installSeed      how a one-shot command runs at setup time. Home Manager
#                    has an activation DAG; devenv has tasks. Neither is
#                    expressible in the other's vocabulary.
#
# Everything else — the options, the path arithmetic, which command runs — is
# computed here once.
{
  installPackages,
  installEnv,
  installSeed,
}: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.kirocrew;

  # Upstream's own layout, mirrored rather than guessed: `config/paths.py` roots
  # the data home at `~/.kiro/crew` (CONFIG_DIR_NAME), `apps/manager.py`'s
  # `app_data_dir` appends `apps/<name>/data`, and
  # `pptx_maker/backend/paths.py` appends `vendor/<_ENGINE_DIRNAME>` with
  # APP_NAME = "pptx-maker". The last segment comes from the engine's own
  # `passthru.engineDirName` so it is not spelled a second time here.
  #
  # A SHELL EXPRESSION, not a Nix path: `$HOME` is resolved by the shell that
  # runs the seed, because neither backend can name the user's home at eval
  # time in a way the other shares. The seed takes this as argv for the same
  # reason — see `lib/seedEngine.nix`.
  crewHome =
    if cfg.dataDir != null
    then lib.escapeShellArg cfg.dataDir
    else "\"$HOME\"/.kiro/crew";

  engineRoot = "${crewHome}/apps/pptx-maker/data/vendor/${cfg.pptxEngine.package.engineDirName}";

  seedEngine = import ../lib/seedEngine.nix {inherit lib pkgs;} {
    engine = cfg.pptxEngine.package;
  };
in {
  options.services.kirocrew = import ./options.nix {inherit lib pkgs;};

  # The module system must discover top-level definition names before it can
  # resolve config. Keep conditions deferred with mkIf or inside a backend's
  # fixed option prefix; optionalAttrs here would read cfg while building the
  # same config, even when the outer enable condition is false.
  config = lib.mkIf cfg.enable (lib.mkMerge [
    (installPackages [cfg.package])

    # Only when the user actually relocated the data home. Exporting
    # KIROCREW_HOME set to its own default is NOT a no-op upstream: several
    # behaviors key off whether the home is the default one, including the
    # recovery breadcrumb written beside `~/.kiro` and the beacon's
    # `is_default_home()` suppression.
    (installEnv {
      inherit lib;
      enable = cfg.enable && cfg.dataDir != null;
      env = {KIROCREW_HOME = cfg.dataDir;};
    })

    (lib.mkIf cfg.pptxEngine.enable (installSeed {
      inherit lib;
      name = "kiroCrewPptxEngine";
      command = "${lib.getExe seedEngine} ${engineRoot}";
    }))
  ]);
}
