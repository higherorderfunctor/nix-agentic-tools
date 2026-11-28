# Synthetic shared-surface producers over the three layers. Nothing here
# imports a production runtime: each runtime is a `runtimeModule` plus a skill
# producer, and the root AGENTS.md composer is a plain layer-2 module. Context
# arbitration (agreement, replacement, suppression) stays upstream in the
# composer; files only sees its one emitted entry or none. Conflicting runtime
# claims on one path are proven by runtime-forward.nix's "runtime collision".
{
  harness,
  lib,
  pkgs,
  ...
}: let
  fileLib = import ../lib/files/default.nix {inherit lib pkgs;};
  runtimeModule = import ../lib/runtime.nix;
  skill = ./fixtures/skill;
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
  skillPath = runtime: "${runtime.prefix}/review";
  # Each runtime renders the shared skill pool under its own prefix at layer 1.
  producer = runtime: {
    imports = [(runtimeModule {inherit (runtime) enabled name;})];
    ai.${runtime.name}.files.${skillPath runtime} = {
      content.source = skill;
      recursive = true;
    };
  };
  # The composer emits its already-arbitrated text once at layer 2, or nothing.
  composer = text: {
    ai.files."AGENTS.md" = {
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
  summary = item: {
    inherit (item) method path;
    content = lib.mapAttrs (_: toString) item.content;
  };
  link = path: leaf: {
    inherit path;
    content.source = toString (skill + "/${leaf}");
    method = "symlink";
  };
  # Pin the runtime prefixes and both fixture leaves independently of the
  # producers, so a missing runtime or leaf cannot shrink the expectation.
  expected = [
    (link ".agents/skills/review/SKILL.md" "SKILL.md")
    (link ".agents/skills/review/references/deep/guide.md" "references/deep/guide.md")
    (link ".claude/skills/review/SKILL.md" "SKILL.md")
    (link ".claude/skills/review/references/deep/guide.md" "references/deep/guide.md")
    (link ".kiro/skills/review/SKILL.md" "SKILL.md")
    (link ".kiro/skills/review/references/deep/guide.md" "references/deep/guide.md")
    {
      content.text = "A\nB";
      method = "ro";
      path = "AGENTS.md";
    }
  ];
  config = evaluate [(composer "A\nB")];
  plan = fileLib.normalize {
    backend = "devenv";
    files = config.ai.files;
    namespace = "ai";
  };
  holds = harness.checkRows "shared surfaces" {
    "claims name each active runtime" =
      config.ai.claims.path
      == {
        ".agents/skills/review" = ["codex"];
        ".claude/skills/review" = ["claude"];
        ".kiro/skills/review" = ["kiro"];
      };
    "devenv delivers only active runtimes' leaves and one root context" = map summary plan == expected;
  };
in {
  checks.ai-module-shared-surfaces = assert holds;
    pkgs.runCommandLocal "ai-module-shared-surfaces" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      printf 'PASS: shared skills and one composed root context\n' > "$out"
    '';
}
