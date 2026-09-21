# Does the module evaluate, and does it DO the thing it exists to do?
#
# The package layer already proves its own derivations are correct. What it
# could not prove — and what shipped broken once — is that anything CONSUMES
# them. That is what these assert, on both backends, from the same options.
{
  lib,
  harness,
  ...
}: let
  inherit (harness) evalDevenv mkTest;

  # The shared harness stubs only HM effects used by existing integrations.
  # Declare this module's additional effect locally, keeping option checking
  # enabled and checking the actual environment value in the relocation test.
  evalHm = config:
    (harness.evalHm config).extendModules {
      modules = [
        {
          options.home.sessionVariables = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {};
          };
        }
      ];
    };

  enabled = {services.kirocrew.enable = true;};

  # The seed command as each backend renders it. Home Manager puts it in an
  # activation DAG entry; devenv puts it in a task. Different carriers, and the
  # contract is that the COMMAND inside them is identical.
  # The harness's entryAfter stub stores the body in text (real HM uses data).
  hmSeed = evaluated: evaluated.config.home.activation.kiroCrewPptxEngine.text;
  devenvSeed = evaluated: evaluated.config.tasks."kirocrew:seed-pptx-engine".exec;
in {
  checks = {
    # Nothing at all until asked for. A module that installs on import is a
    # module nobody can adopt incrementally.
    module-kiro-crew-default-disabled = mkTest "kiro-crew-default-disabled" (
      let
        hm = evalHm {};
        devenv = evalDevenv {};
      in
        !hm.config.services.kirocrew.enable
        && !devenv.config.services.kirocrew.enable
        && !(hm.config.home.activation ? kiroCrewPptxEngine)
        && !(devenv.config.tasks ? "kirocrew:seed-pptx-engine")
    );

    # THE CONSUMPTION ASSERTION, and the reason this file exists. Enabling the
    # module must install the package AND seed the engine, on both backends.
    module-kiro-crew-installs-and-seeds = mkTest "kiro-crew-installs-and-seeds" (
      let
        hm = evalHm enabled;
        devenv = evalDevenv enabled;
        # A name prefix also accepts the engine package. Require the selected
        # application derivation itself to appear in each backend's packages.
        installsPackage = expected: packages:
          builtins.any (drv: drv.outPath == expected.outPath) packages;
        seedsEngine = command:
          lib.hasInfix "kiro-crew-seed-pptx-engine" command
          && lib.hasInfix "apps/pptx-maker/data/vendor/sdpm" command;
      in
        installsPackage hm.config.services.kirocrew.package hm.config.home.packages
        && installsPackage devenv.config.services.kirocrew.package devenv.config.packages
        && seedsEngine (hmSeed hm)
        && seedsEngine (devenvSeed devenv)
    );

    # The two backends must run the SAME command. They differ only in carrier,
    # and a divergence here is the parity bug this shared-options shape exists
    # to make impossible — so assert it rather than trust the shape.
    module-kiro-crew-backend-parity = mkTest "kiro-crew-backend-parity" (
      let
        hm = evalHm enabled;
        devenv = evalDevenv enabled;
        # The HM body is wrapped in a strict-mode subshell and the devenv body
        # carries the header inline, so compare the seed invocation itself.
        seedLine = text:
          lib.findFirst (l: lib.hasInfix "kiro-crew-seed-pptx-engine" l) null
          (lib.splitString "\n" text);
      in
        seedLine (hmSeed hm)
        != null
        && seedLine (hmSeed hm) == seedLine (devenvSeed devenv)
    );

    # Relocating the data home must move the SEED too, or the engine lands
    # somewhere the gateway never looks and the packaging silently does nothing.
    module-kiro-crew-datadir-moves-the-seed = mkTest "kiro-crew-datadir-moves-the-seed" (
      let
        relocated = {
          services.kirocrew = {
            enable = true;
            dataDir = "/var/lib/kirocrew";
          };
        };
        hm = evalHm relocated;
        devenv = evalDevenv relocated;
        moved = command:
          lib.hasInfix "/var/lib/kirocrew/apps/pptx-maker/data/vendor/sdpm" command
          && !(lib.hasInfix ".kiro/crew" command);
      in
        moved (hmSeed hm)
        && moved (devenvSeed devenv)
        && hm.config.home.sessionVariables.KIROCREW_HOME == "/var/lib/kirocrew"
        && devenv.config.env.KIROCREW_HOME == "/var/lib/kirocrew"
    );

    # Opting out of the seed must leave no carrier behind on either backend.
    module-kiro-crew-pptx-engine-opt-out = mkTest "kiro-crew-pptx-engine-opt-out" (
      let
        off = {
          services.kirocrew = {
            enable = true;
            pptxEngine.enable = false;
          };
        };
        hm = evalHm off;
        devenv = evalDevenv off;
      in
        !(hm.config.home.activation ? kiroCrewPptxEngine)
        && !(devenv.config.tasks ? "kirocrew:seed-pptx-engine")
    );
  };
}
