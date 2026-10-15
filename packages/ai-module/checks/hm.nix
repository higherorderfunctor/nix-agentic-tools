{
  harness,
  lib,
  pkgs,
  ...
}: let
  dagLib = import ./dag-lib.nix lib;
  evaluateWith = definitions: overrides:
    (lib.evalModules {
      specialArgs = {
        lib = dagLib;
        inherit pkgs;
      };
      modules = [harness.hmStubs ../modules/homeManager/default.nix {ai.files2 = definitions;} overrides];
    }).config;
  evaluate = definitions: evaluateWith definitions {};
  methods = ["symlink" "ro" "rw" "symlink" "symlink" "ro"];
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
  empty = evaluate {};
  disabled = evaluate {
    "settings.json".enable = false;
  };
  run = evaluate {
    secret = {
      content.run = ''${pkgs.coreutils}/bin/cat "$HOME/provider"'';
      method = "ro";
    };
  };
  forcedEmpty = evaluateWith {} {ai.activation2 = lib.mkForce {};};
  nested = evaluate {
    "linked/settings.json" = {
      content.text = "{}";
      method = "symlink";
    };
  };
  python = pkgs.python3.withPackages (ps: [ps.pyyaml ps.tomlkit]);
  # The generated files2 entries a config emits, in execution order.
  phases = config: map (name: config.home.activation.${name}.text) (builtins.filter (name: config.home.activation ? ${name}) ["ai2-files2-prune" "ai2-files2-apply"]);
  fixture = pkgs.writeText "files2-hm-fixture.json" (builtins.toJSON {
    generations =
      map (config: {
        apply = config.home.activation.ai2-files2-apply.text;
        prune = config.home.activation.ai2-files2-prune.text;
        links = lib.mapAttrs (_: item: "${item.source}") config.home.file;
      })
      evaluated;
    disabled = phases disabled;
    drain = phases empty;
    forcedDrain = phases forcedEmpty;
    nested = nested.home.activation.ai2-files2-prune.text;
    python = "${python}";
    run = phases run;
  });
  runShim = pkgs.writeText "files2-hm-run.sh" harness.hmRunShim;
  tree = evaluate {
    tree = {
      content.source = ./fixtures/a;
      recursive = true;
    };
  };
  # The directory symlink `link` is delivered as one link, not walked into.
  linkedStore = "${./fixtures}";
  linked = evaluate {
    linked = {
      content.source = linkedStore;
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
  graph = empty.home.activation;
  applied = (builtins.head evaluated).home.activation.ai2-files2-apply;
  reservedOverride = builtins.tryEval (builtins.deepSeq
    (evaluateWith {} {ai.activation2.files2-prune.command = "override";}).home.activation
    true);
  forcedOverride = builtins.tryEval (builtins.deepSeq
    (evaluateWith {} {ai.activation2 = lib.mkForce {files2-prune.command = "override";};}).home.activation
    true);
  failures =
    lib.optional reservedOverride.success "reserved entry override"
    ++ lib.optional forcedOverride.success "forced reserved entry override"
    ++ lib.optional (map (item: builtins.attrNames item.home.file) evaluated != [["settings.json"] [] [] ["settings.json"] ["settings.json"] []]) "method sink"
    ++ lib.optional (builtins.attrNames tree.home.file != ["tree/b/c.md"]) "recursive leaves"
    ++ lib.optional (builtins.attrNames directory.home.file != ["directory"]) "directory link"
    ++ lib.optional (lib.mapAttrs (_: item: "${item.source}") (lib.filterAttrs (name: _: lib.hasPrefix "linked/link" name) linked.home.file) != {"linked/link" = "${linkedStore}/link";} || !linked.home.file ? "linked/a/b/c.md") "directory symlink leaf"
    ++ lib.optional (executable.home.file.script.executable != true) "executable link"
    ++ lib.optional (builtins.attrNames graph != ["ai2-files-ready" "ai2-files2-prune" "ai2-ready"]) "empty plan emits only prune"
    ++ lib.optional (builtins.attrNames forcedEmpty.home.activation != builtins.attrNames graph) "forced empty drain"
    ++ lib.optional (graph.ai2-files2-prune.before != ["checkLinkTargets"] || graph.ai2-files2-prune.after != []) "prune edge"
    ++ lib.optional (applied.after != ["linkGeneration" "ai2-files2-prune"] || applied.before != ["ai2-files-ready"]) "apply edge"
    ++ lib.optional (run.home.activation.ai2-files2-apply.after != ["linkGeneration" "sops-nix" "ai2-files2-prune"]) "provider edge"
    ++ lib.optional (builtins.attrNames disabled.home.activation != builtins.attrNames graph) "disabled drain";
in {
  checks.files2-hm = assert lib.assertMsg (failures == []) "files2 HM fixtures failed: ${lib.concatStringsSep ", " failures}";
    pkgs.runCommandLocal "files2-hm" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${python}/bin/python3 -I ${./hm.py} ${fixture} ${pkgs.bash}/bin/bash ${runShim}
      ${pkgs.coreutils}/bin/printf 'PASS: files2 hm\n' > "$out"
    '';
}
