# PR 3 chunk 4: the devenv observer (L168, L169). Its graph edges are asserted
# here; observer.py executes the generated snapshot and inspect tasks on real
# directories for an engine path, an old path and an unclaimed recursive one.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  shared = {
    ai.codex = {
      enable = true;
      files."seeded".content.text = "seeded";
    };
    files."seeded".copyMode = "seed";
  };
  # `before` declares every observed path; `after` retires them all, hands
  # `probe` to the consumer and turns the `moved.json` link into an owned
  # engine copy, neither of which is a removal.
  configs = {
    after = lib.recursiveUpdate shared {
      ai.files2."moved.json" = {
        content.value.moved = true;
        format = "json";
        method = "rw";
      };
      files."probe".text = "consumer";
    };
    before = lib.recursiveUpdate shared {
      ai.codex = {
        files = lib.genAttrs ["moved.json" "old.md" "probe"] (name: {content.text = name;});
        files2."new.md".content.text = "new";
      };
      ai.files2.tree = {
        content.source = ./fixtures/tree;
        recursive = true;
      };
      files."consumer.md".text = "consumer";
    };
    empty = {};
  };
  evaluated = lib.mapAttrs (_: config: (harness.evalDevenv config).config) configs;
  edges = task: {inherit (task) after before;};
  failures =
    lib.optional (edges evaluated.before.tasks."ai2:files2-snapshot"
      != {
        after = [];
        before = ["devenv:files:cleanup"];
      }) "snapshot precedes cleanup"
    ++ lib.optional (edges evaluated.before.tasks."ai2:files2-inspect"
      != {
        after = ["ai2:files-ready"];
        before = ["devenv:enterShell"];
      }) "inspect follows materialized"
    ++ lib.optional (!(evaluated.before.tasks."ai2:files2-inspect".showOutput or false)) "inspect output shown";
  fixture = builtins.toJSON (lib.mapAttrs (_: config: {
      inspect = config.tasks."ai2:files2-inspect".exec;
      links = lib.mapAttrs (_: file: "${file.file}") (lib.filterAttrs (_: file: file.copyMode == "symlink") config.files);
      snapshot = config.tasks."ai2:files2-snapshot".exec;
    })
    evaluated);
in {
  checks.ai-module-observer = assert lib.assertMsg (failures == []) "ai-module observer: ${lib.concatStringsSep ", " failures}";
    pkgs.runCommandLocal "ai-module-observer" {passthru = {inherit fixture;};} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.python3}/bin/python3 -I ${./observer.py} ${pkgs.writeText "ai-module-observer.json" fixture} ${pkgs.bash}/bin/bash
      ${pkgs.coreutils}/bin/printf 'PASS: ai-module observer\n' > "$out"
    '';
}
