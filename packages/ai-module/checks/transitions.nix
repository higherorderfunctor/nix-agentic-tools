# Generated generations executed end to end on both backends. Each
# scenario is a list of steps; a step declares `ai.files` and can add a
# `native` key to the tree first. Every native key precedes an owned change,
# so the runner expects exactly those bytes backed up and no other backup.
# transitions.py runs the generated prune/guard/apply bodies
# around a stand-in native link step on a fresh root and asserts disk and
# state against the declared expectations, not the generated plan.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  backends = import ./backends.nix {inherit harness lib pkgs;};
  fileLib = import ../lib/files/default.nix {inherit lib pkgs;};
  methods = ["ro" "rw" "symlink"];
  # Text content keeps every plan free of build-time renderings, so the
  # runtime test needs no local build; `rw` parses it as declared keys.
  documents = {
    json = ''{"k": "v"}'';
    toml = ''k = "v"'';
    yaml = "k: v\n";
  };
  documentStep = paths: method: format: {
    files = lib.genAttrs paths (_: {
      content.text = documents.${format};
      inherit format method;
    });
    # The runtime assertions must still see these members if normalization drops
    # a file, changes its method or content, or emits an empty plan.
    want = lib.genAttrs paths (_: {
      inherit format method;
      text = documents.${format};
    });
  };
  tree = ./fixtures/tree;
  treeStep = method: {
    files.tree = {
      content.source = tree;
      recursive = true;
      inherit method;
    };
    want = {
      "tree/bin/tool" = {
        format = "raw";
        inherit method;
        mode = "0555";
        source = "${tree + "/bin/tool"}";
      };
      "tree/nested/deep/leaf.md" = {
        format = "raw";
        inherit method;
        mode = "0444";
        source = "${tree + "/nested/deep/leaf.md"}";
      };
    };
  };
  # Directed switches distinguish unlinking native links, retiring owned data,
  # and recording the new owner. Format rows exercise replacement for ro and
  # preservation of a program-written key during rw re-encoding. Retirement
  # must leave native keys behind while removing the last owned file and its state.
  scenarios =
    lib.concatMap (from:
      map (to: {
        name = "switch-${from}-${to}";
        value = map (method: documentStep ["doc"] method "json") [from to];
      }) (lib.remove from methods))
    methods
    ++ map (method: {
      name = "format-${method}";
      value = lib.imap0 (index: format:
        documentStep ["doc"] method format
        // lib.optionalAttrs (method == "rw" && index == 1) {actions = ["native"];}) ["json" "toml" "yaml"];
    }) ["ro" "rw"]
    ++ map (method: {
      name = "tree-${method}";
      value = [(treeStep method)];
    }) ["ro" "symlink"]
    ++ [
      {
        name = "retire";
        value = [
          (lib.foldl' lib.recursiveUpdate {} (map (method: documentStep [method] method "json") methods))
          {
            actions = ["native"];
            files = {};
            want = {};
          }
        ];
      }
    ];
  generate = backend: declared: let
    sink = backends.sinks.${backend};
    config = backends.evaluate backend {inherit (declared) files;};
    phases = sink.phases config;
    links = lib.mapAttrs (_: sink.target) (sink.native config);
    plan = fileLib.normalize {
      inherit backend;
      files = config.ai.files;
      namespace = "ai";
    };
    stored = name: value: {
      path = "${pkgs.writeText name (builtins.toJSON value)}";
      inherit value;
    };
  in {
    actions = declared.actions or [];
    commands = lib.genAttrs phases (phase: sink.command (sink.entry config phase));
    inherit (declared) want;
    inherit links;
    # Generated JSON inputs, by store path; the runner substitutes identical
    # local copies so it can execute without building them.
    replacements = [(stored "files-ai-plan.json" plan)] ++ lib.optional (builtins.elem "guard" phases) (stored "files-ai-native.json" links);
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
