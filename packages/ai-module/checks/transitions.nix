# Chunk 5b: generated generations executed end to end on both backends. Each
# scenario is a list of steps; a step declares `ai.files2`, optionally acts on
# the tree first (`edit` an owned copy, add a `native` key, `seed` identical
# bytes) and names extra expectations. Every edit or native key precedes an
# owned change, so the runner expects exactly those bytes backed up and no
# other backup. transitions.py runs the generated prune/guard/apply bodies
# around a stand-in native link step on a fresh root and asserts disk and
# state against each step's plan.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  backends = import ./backends.nix {inherit harness lib pkgs;};
  files2 = import ../lib/files/default.nix {inherit lib pkgs;};
  methods = ["ro" "rw" "symlink"];
  # Text content keeps every plan free of build-time renderings, so the
  # runtime test needs no local build; `rw` parses it as declared keys.
  documents = {
    json = ''{"k": "v"}'';
    toml = ''k = "v"'';
    yaml = "k: v\n";
  };
  document = method: format: {
    content.text = documents.${format};
    inherit format method;
  };
  step = files: {inherit files;};
  scenarios =
    lib.concatMap (from:
      map (to: {
        name = "switch-${from}-${to}";
        value = map (method: step {doc = document method "json";}) [from to];
      }) (lib.remove from methods))
    methods
    ++ lib.concatMap (method: [
      {
        name = "format-${method}";
        value = lib.imap0 (index: format:
          step {doc = document method format;}
          // lib.optionalAttrs (method == "rw" && index == 1) {actions = ["native"];}) ["json" "toml" "yaml"];
      }
      {
        name = "adopt-${method}";
        value = [
          (step {doc = document method "json";}
            // {
              actions = ["seed"];
              expect = ["adopted"];
            })
        ];
      }
    ]) ["ro" "rw"]
    ++ map (method: {
      name = "tree-${method}";
      value = [
        (step {
            tree = {
              content.source = ./fixtures/tree;
              recursive = true;
              inherit method;
            };
          }
          // {executable = ["tree/bin/tool"];})
      ];
    }) ["ro" "symlink"]
    ++ [
      {
        name = "backup";
        value = [
          (step {doc = document "ro" "json";})
          (step {doc = document "ro" "json";} // {actions = ["edit"];})
        ];
      }
      {
        name = "retire";
        value = [
          (step (lib.genAttrs methods (method: document method "json")))
          (step {} // {actions = ["native"];})
        ];
      }
    ];
  generate = backend: declared: let
    sink = backends.sinks.${backend};
    config = backends.evaluate backend declared.files;
    phases = sink.phases config;
    links = lib.mapAttrs (_: sink.target) (sink.native config);
    plan = files2.normalize {
      inherit backend;
      files = config.ai.files2;
      namespace = "ai";
    };
    stored = name: value: {
      path = "${pkgs.writeText name (builtins.toJSON value)}";
      inherit value;
    };
  in {
    actions = declared.actions or [];
    commands = lib.genAttrs phases (phase: sink.command (sink.entry config phase));
    executable = declared.executable or [];
    expect = declared.expect or [];
    inherit links plan;
    # Generated JSON inputs, by store path; the runner substitutes identical
    # local copies so it can execute without building them.
    replacements = [(stored "files2-ai-plan.json" plan)] ++ lib.optional (builtins.elem "guard" phases) (stored "files2-ai-native.json" links);
  };
  fixtureJson = builtins.toJSON (lib.genAttrs (builtins.attrNames backends.sinks) (backend:
    builtins.listToAttrs (map (scenario: {
        inherit (scenario) name;
        value = map (generate backend) scenario.value;
      })
      scenarios)));
in {
  checks.ai-module-transitions = pkgs.runCommandLocal "ai-module-transitions" {passthru = {inherit fixtureJson;};} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.python3.withPackages (ps: [ps.pyyaml ps.tomlkit])}/bin/python3 -I ${./transitions.py} \
      ${pkgs.writeText "ai-module-transitions.json" fixtureJson} ${pkgs.bash}/bin/bash ${pkgs.writeText "hm-run.sh" harness.hmRunShim}
    ${pkgs.coreutils}/bin/printf 'PASS: ai-module transitions\n' > "$out"
  '';
}
