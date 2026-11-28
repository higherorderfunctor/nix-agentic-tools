{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) checkRows rejectsChange;
  dagLib = import ./dag-lib.nix lib;
  evaluateWith = definitions: overrides:
    (lib.evalModules {
      specialArgs = {
        lib = dagLib;
        inherit pkgs;
      };
      modules = [harness.hmStubs ../modules/homeManager/default.nix {ai.files = definitions;} overrides];
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
  forcedEmpty = evaluateWith {} {ai.activation = lib.mkForce {};};
  nested = evaluate {
    "linked/settings.json" = {
      content.text = "{}";
      method = "symlink";
    };
  };
  python = pkgs.python3.withPackages (ps: [ps.pyyaml ps.tomlkit]);
  # The generated files entries a config emits, in execution order.
  phases = config: map (name: config.home.activation.${name}.text) (builtins.filter (name: config.home.activation ? ${name}) ["ai-files-prune" "ai-files-apply"]);
  fixture = pkgs.writeText "files-hm-fixture.json" (builtins.toJSON {
    generations =
      map (config: {
        apply = config.home.activation.ai-files-apply.text;
        prune = config.home.activation.ai-files-prune.text;
        links = lib.mapAttrs (_: item: "${item.source}") config.home.file;
      })
      evaluated;
    disabled = phases disabled;
    drain = phases empty;
    nested = nested.home.activation.ai-files-prune.text;
    python = "${python}";
    run = phases run;
  });
  runShim = pkgs.writeText "ai-module-files-hm-run.sh" harness.hmRunShim;
  directory = evaluate {directory.content.source = ./fixtures/a;};
  graph = empty.home.activation;
  applied = (builtins.head evaluated).home.activation.ai-files-apply;
  # Reading the lowered prune edge forces the backend's reserved-name guard.
  reservedEntries = checkRows "Home Manager generated activation entries" {
    "forced pool cannot replace files-prune" = rejectsChange (name: (evaluateWith {} {ai.activation = lib.mkForce {${name}.command = "true";};}).home.activation.ai-files-prune.before) {
      valid = "probe";
      invalid = "files-prune";
      expected = ["checkLinkTargets"];
    };
  };
  sinkRows = checkRows "Home Manager files" {
    "apply waits for links and prune but precedes readiness" = applied.after == ["linkGeneration" "ai-files-prune"] && applied.before == ["ai-files-ready"];
    "directory source without recursion is delivered as one link" = builtins.attrNames directory.home.file == ["directory"];
    "disabled files emit no apply but keep prune" = builtins.attrNames disabled.home.activation == builtins.attrNames graph;
    "empty plan emits no apply but keeps prune" = builtins.attrNames graph == ["ai-files-prune" "ai-files-ready" "ai-ready"];
    "forced empty activation cannot erase engine entries" = builtins.attrNames forcedEmpty.home.activation == builtins.attrNames graph;
    "prune precedes native link collision checks" = graph.ai-files-prune.before == ["checkLinkTargets"] && graph.ai-files-prune.after == [];
    "renderer apply waits for secret readiness as well as links" = run.home.activation.ai-files-apply.after == ["linkGeneration" "sops-nix" "ai-files-prune"];
  };
in {
  checks.ai-module-files-hm = assert reservedEntries;
  assert sinkRows;
    pkgs.runCommandLocal "ai-module-files-hm" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${python}/bin/python3 -I ${./hm.py} ${fixture} ${pkgs.bash}/bin/bash ${runShim}
      ${pkgs.coreutils}/bin/printf 'PASS: files hm\n' > "$out"
    '';
}
