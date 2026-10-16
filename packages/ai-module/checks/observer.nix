# PR 3 chunk 4: the devenv observer (L168, L169). Its graph edges are asserted
# here; observer.py executes the generated snapshot and inspect tasks on real
# directories for layer-1 entries and an unclaimed recursive entry.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  shared = {ai.codex.enable = true;};
  # `after` retires the observed links and turns `moved.json` into an owned
  # engine copy. An unclaimed consumer link stays outside observation.
  configs = {
    after = lib.recursiveUpdate shared {
      ai.files."moved.json" = {
        content.value.moved = true;
        format = "json";
        method = "rw";
      };
      files."consumer.md".text = "consumer";
    };
    before = lib.recursiveUpdate shared {
      ai.codex = {
        files = lib.genAttrs ["moved.json" "new.md"] (name: {content.text = name;});
      };
      ai.files.tree = {
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
    lib.optional (edges evaluated.before.tasks."ai:files-snapshot"
      != {
        after = [];
        before = ["devenv:files:cleanup"];
      }) "snapshot precedes cleanup"
    ++ lib.optional (edges evaluated.before.tasks."ai:files-inspect"
      != {
        after = ["ai:files-ready"];
        before = ["devenv:enterShell"];
      }) "inspect follows materialized"
    ++ lib.optional (!(evaluated.before.tasks."ai:files-inspect".showOutput or false)) "inspect output shown";
  fixture = builtins.toJSON (lib.mapAttrs (_: config: {
      inspect = config.tasks."ai:files-inspect".exec;
      links = lib.mapAttrs (_: file: "${file.file}") (lib.filterAttrs (_: file: file.copyMode == "symlink") config.files);
      snapshot = config.tasks."ai:files-snapshot".exec;
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
