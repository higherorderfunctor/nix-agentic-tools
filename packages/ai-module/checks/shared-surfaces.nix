# Synthetic shared-surface producers over the three layers. Nothing here
# imports a production runtime: each runtime is a `runtimeModule` plus a skill
# producer, and the root AGENTS.md composer is a plain layer-2 module. Context
# arbitration (agreement, replacement, suppression) stays upstream in the
# composer; files2 only sees its one emitted entry or none. Conflicting runtime
# claims on one path are proven by runtime-forward.nix's "runtime collision".
{
  lib,
  pkgs,
  ...
}: let
  files2 = import ../lib/files/default.nix {inherit lib pkgs;};
  runtimeModule = import ../lib/runtime.nix;
  skill = ./fixtures/skill;
  # Written independently of the walker: the fixture's leaves, nested dirs included.
  skillLeaves = ["SKILL.md" "references/deep/guide.md"];
  runtimes = [
    {
      enabled = true;
      name = "claude";
      prefix = ".claude/skills";
    }
    {
      enabled = true;
      name = "codex";
      prefix = ".agents/skills";
    }
    {
      enabled = true;
      name = "kiro";
      prefix = ".kiro/skills";
    }
    {
      enabled = false;
      name = "retired";
      prefix = ".retired/skills";
    }
  ];
  enabled = builtins.filter (runtime: runtime.enabled) runtimes;
  skillPath = runtime: "${runtime.prefix}/review";
  # Each runtime renders the shared skill pool under its own prefix at layer 1.
  producer = runtime: {
    imports = [(runtimeModule {inherit (runtime) enabled name;})];
    ai.${runtime.name}.files2.${skillPath runtime} = {
      content.source = skill;
      recursive = true;
    };
  };
  # The composer emits its already-arbitrated text once at layer 2, or nothing.
  composer = text: {
    ai.files2."AGENTS.md" = {
      content.text = text;
      format = "markdown";
      method = "ro";
    };
  };
  evaluate = modules:
    (lib.evalModules {
      specialArgs = {inherit pkgs;};
      modules = [../modules/common.nix] ++ map producer runtimes ++ modules;
    }).config;
  plan = backend: config:
    files2.normalize {
      inherit backend;
      files = config.ai.files2;
      namespace = "ai";
      owners = config.ai.files2Owners;
    };
  backends = ["devenv" "hm"];
  summary = item: {
    inherit (item) method path;
    content = lib.mapAttrs (_: toString) item.content;
  };
  skillPlan = lib.concatMap (runtime:
    map (leaf: {
      content.source = "${toString skill}/${leaf}";
      method = "symlink";
      path = "${skillPath runtime}/${leaf}";
    })
    skillLeaves)
  enabled;
  check = text: let
    config = evaluate [(composer text)];
    expected = lib.sort (a: b: a.path < b.path) (skillPlan
      ++ [
        {
          content.text = text;
          method = "ro";
          path = "AGENTS.md";
        }
      ]);
  in
    lib.optional (lib.any (path: lib.hasPrefix ".retired/" path) (builtins.attrNames config.ai.files2)) "disabled runtime reached layer 2"
    ++ lib.optional (config.ai.files2Owners != lib.listToAttrs (map (runtime: lib.nameValuePair (skillPath runtime) [runtime.name]) enabled)) "owners"
    ++ lib.concatMap (backend: lib.optional (map summary (plan backend config) != expected) "${backend}: plan") backends;
  failures = check "A\nB";
in {
  checks.ai-module-shared-surfaces = assert lib.assertMsg (failures == []) "shared surfaces: ${lib.concatStringsSep ", " failures}";
    pkgs.runCommandLocal "ai-module-shared-surfaces" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      printf 'PASS: shared skills and one composed root context\n' > "$out"
    '';
}
