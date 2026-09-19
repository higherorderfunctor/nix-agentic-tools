# The delivery layer's own module contracts: what `ai.<runtime>.activation`
# lowers to on each backend, and what the adapters do with it.
#
# The gate next door proves that a writer the POLICY names survives a populated
# and an emptied declaration. This proves the layer underneath it: that a
# writer declared once reaches both backends with the ordering it asked for,
# that a token without a node on this backend is dropped instead of emitted as
# a name the runner would reject, and that the body is spliced in a shape that
# cannot leak shell options into the script it joins.
{
  harness,
  lib,
  ...
}: let
  inherit (harness) evalDevenv evalHm harnessNames mkTest;

  # One writer, both backends, every ordering feature: a backend-keyed entry
  # name, a token with no devenv node (`secrets`), the literal-node escape
  # hatch, and both ends of the position.
  migrator = runtime: {
    ai.${runtime} = {
      enable = true;
      activation.probeMigrate = {
        after = ["secrets"];
        afterNodes.hm = ["probeSecretProvider"];
        before = ["linkCheck" "shell"];
        command = "printf 'probe'";
        entry = {
          devenv = "ai:probe:migrate";
          hm = "probeMigrate";
        };
      };
    };
  };
  # `exit` would truncate the whole concatenated activation script, so match
  # the WORD: `inherit_errexit` carries the substring and must not trip this.
  usesExit = line: builtins.match "(.*[^_[:alnum:]])?exit([^_[:alnum:]].*)?" line != null;
  strict = body:
    lib.hasInfix "set -euETo pipefail" body
    && lib.hasInfix "shopt -s inherit_errexit 2>/dev/null || :" body
    && lib.hasPrefix "(" body
    && !lib.any usesExit (lib.splitString "\n" body);
in {
  checks = {
    module-delivery-command-writer-lowers-to-both-backends = mkTest "delivery-command-writer-lowers-to-both-backends" (
      let
        # Kiro declares no devenv files when bare-enabled, so the task's edge
        # list here is exactly what the writer asked for.
        hm = (evalHm (migrator "kiro")).config;
        devenv = (evalDevenv (migrator "kiro")).config;
        entry = hm.home.activation.probeMigrate;
        task = devenv.tasks."ai:probe:migrate";
      in
        # Home Manager gets both ends of the position, the abstract `secrets`
        # token resolved to its node, and the literal escape hatch appended
        # rather than substituted.
        entry.after
        == ["sops-nix" "probeSecretProvider"]
        && entry.before == ["checkLinkTargets"]
        && strict entry.text
        && lib.hasInfix "printf 'probe'" entry.text
        # devenv has no secret-provider node, so that token lowers to nothing
        # instead of a dangling task reference its runner would reject.
        && task.after == []
        && task.before == ["devenv:enterShell"]
        && strict task.exec
        && lib.hasInfix "printf 'probe'" task.exec
    );

    module-delivery-command-writer-default-edges = mkTest "delivery-command-writer-default-edges" (
      let
        config = {
          ai.claude = {
            enable = true;
            activation.probeDefaults.command = "printf 'probe'";
          };
        };
        hm = (evalHm config).config;
        devenv = (evalDevenv config).config;
      in
        # The default tokens are `after = ["files"]` and `before = ["shell"]`,
        # and the writer's own attribute name is its default entry name.
        # `shell` has no Home Manager node, so it lowers to nothing there.
        hm.home.activation.probeDefaults.after
        == ["linkGeneration"]
        && hm.home.activation.probeDefaults.before == []
        && devenv.tasks.probeDefaults.after == ["devenv:files:cleanup"]
        && lib.elem "devenv:enterShell" devenv.tasks.probeDefaults.before
    );

    # `tasks."devenv:files"` exists only when the project declares files, and
    # devenv's runner hard-errors on a dangling reference — so this edge is
    # conditional, and both arms of the condition are pinned.
    module-delivery-devenv-files-edge-is-conditional = mkTest "delivery-devenv-files-edge-is-conditional" (
      let
        # Kiro is the one runtime that declares no devenv files when it is
        # bare-enabled, so it is the only one that can show the edge ABSENT.
        base = {
          ai.kiro = {
            enable = true;
            activation.probeDefaults.command = "printf 'probe'";
          };
        };
        withFiles =
          (evalDevenv (lib.recursiveUpdate base {
            ai.kiro.files."probe.txt".text = "probe";
          })).config;
        withoutFiles = (evalDevenv base).config;
      in
        withFiles.tasks.probeDefaults.before
        == ["devenv:enterShell" "devenv:files"]
        && withoutFiles.files == {}
        && withoutFiles.tasks.probeDefaults.before == ["devenv:enterShell"]
    );

    module-delivery-writers-reach-every-runtime = mkTest "delivery-writers-reach-every-runtime" (
      lib.all (runtime: let
        hm = (evalHm (migrator runtime)).config;
        devenv = (evalDevenv (migrator runtime)).config;
        disabled = evalHm (lib.recursiveUpdate (migrator runtime) {
          ai.${runtime}.enable = false;
        });
      in
        hm.home.activation
        ? probeMigrate
        && devenv.tasks ? "ai:probe:migrate"
        # Delivery is inside the runtime's sole enable gate, exactly like the
        # file sink beside it.
        && !(disabled.config.home.activation ? probeMigrate))
      harnessNames
    );
  };
}
