{
  harness,
  lib,
  pkgs,
  ...
}: let
  files2 = import ../default.nix {inherit lib pkgs;};
  dagLib =
    lib
    // {
      hm.dag = {
        entryAfter = after: text: {inherit after text;};
        entryBefore = before: text: {inherit before text;};
      };
    };
  evaluate = definitions:
    (lib.evalModules {
      specialArgs = {lib = dagLib;};
      modules = [harness.hmStubs (files2.hmModule "fixture") {files2 = definitions;}];
    }).config;
  methods = ["symlink" "ro" "rw" "symlink" "symlink"];
  declarations =
    map (method: {
      "settings.json" = {
        content.text = ''{"owned":1}'';
        executable = true;
        format = "json";
        inherit method;
      };
    })
    methods;
  evaluated = map evaluate declarations;
  plans = map (config:
    files2.normalize {
      backend = "hm";
      files = config.files2;
      namespace = "fixture";
    })
  evaluated;
  lowered = map (plan:
    files2.lowerHm {
      hmLib = dagLib;
      namespace = "fixture";
      inherit plan;
    })
  plans;
  scripts =
    map (config: {
      apply = config.home.activation.files2-fixture-write.text;
      prune = config.home.activation.files2-fixture-prune.text;
      links = lib.mapAttrs (_: item: "${item.source}") config.home.file;
    })
    (evaluated ++ [empty]);
  fixture = pkgs.writeText "files2-hm-fixture.json" (builtins.toJSON scripts);
  runShim = pkgs.writeText "files2-hm-run.sh" harness.hmRunShim;
  tree = evaluate {
    tree = {
      content.source = ./fixtures/a;
      recursive = true;
    };
  };
  directory = evaluate {directory.content.source = ./fixtures/a;};
  executable = evaluate {
    script = {
      content.text = "printf ok";
      executable = true;
    };
  };
  empty = evaluate {};
  run = evaluate {
    secret = {
      content.run = "printf secret";
      method = "ro";
    };
  };
  failures =
    lib.optional (map (item: builtins.attrNames item.home.file) evaluated != [["settings.json"] [] [] ["settings.json"] ["settings.json"]]) "method sink"
    ++ lib.optional (builtins.attrNames tree.home.file != ["tree/b/c.md"]) "recursive leaves"
    ++ lib.optional (builtins.attrNames directory.home.file != ["directory"]) "directory link"
    ++ lib.optional (executable.home.file.script.executable != true) "executable link"
    ++ lib.optional (builtins.attrNames empty.home.activation != ["files2-fixture-prune" "files2-fixture-write"]) "empty drain"
    ++ lib.optional (run.home.activation.files2-fixture-write.after != ["linkGeneration" "sops-nix"]) "provider edge"
    ++ lib.optional (builtins.any (item: item.home.activation.files2-fixture-prune.before != ["checkLinkTargets"] || item.home.activation.files2-fixture-write.after != ["linkGeneration"]) evaluated) "activation edges"
    ++ lib.optional (map (item: builtins.length (builtins.attrNames item.home.file)) lowered != [1 0 0 1 1]) "lowered sink";
in {
  checks.files2-hm = assert lib.assertMsg (failures == []) "files2 HM fixtures failed: ${lib.concatStringsSep ", " failures}";
    pkgs.runCommandLocal "files2-hm" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.python3.withPackages (ps: [ps.pyyaml ps.tomlkit])}/bin/python3 -I ${./hm.py} ${fixture} ${pkgs.bash}/bin/bash ${runShim}
      ${pkgs.coreutils}/bin/printf 'PASS: files2 hm\n' > "$out"
    '';
}
