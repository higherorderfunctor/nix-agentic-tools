# The shared repository AGENTS.md on devenv, through every repository module.
# Its composer (`ai.internal`) is the path's one claimant; a runtime's
# `files."AGENTS.md"` forwards unclaimed and arbitrates by module priority:
# agreeing definitions merge, an ordinary one replaces the composition,
# `enable = false` suppresses it, and divergent ones at one priority fail.
# The old writer's ledger is declared even when nothing contributes, and
# `ai.deliveredPaths` is what the devenv treefmt run excludes.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  path = "AGENTS.md";
  ledger = {
    codec = "dir";
    ledger = "materialize/agents-md.manifest";
    path = ".";
  };
  same = {
    content.text = "SAME";
    format = "markdown";
  };
  # Each row identifies the priority or owner decision it exercises.
  cases = {
    "compatible defaults do not replace composed content" = {
      defs.codex = {
        format = lib.mkDefault "markdown";
        method = lib.mkDefault "ro";
      };
      expect = "composed";
    };
    "disable also hides another runtime replacement" = {
      defs = {
        codex.content.text = "CODEX";
        kiro.enable = false;
      };
      expect = "absent";
    };
    "equal-priority identical replacements merge" = {
      defs = lib.genAttrs defaultRuntimes (_: same);
      expect.text = "SAME";
    };
    "explicit disable hides the composed file" = {
      defs.kiro.enable = false;
      expect = "absent";
    };
    "runtime replacement works without composed context" = {
      context = null;
      defs = lib.genAttrs ["codex" "kimchi"] (_: same);
      enabled = ["codex" "kimchi"];
      expect.text = "SAME";
    };
    "shared context without overrides uses the generated copy" = {
      defs = {};
      expect = "composed";
    };
  };
  evaluate = context: enabled: defs:
    (harness.evalDevenv (lib.foldl' lib.recursiveUpdate (lib.optionalAttrs (context != null) {ai.context.text = context;}) (
      map (runtime: harness.setEnable runtime true) enabled
      ++ lib.mapAttrsToList (runtime: entry: {ai.${runtime}.files.${path} = entry;}) defs
    ))).config;
  defaultRuntimes = ["codex" "kimchi" "kiro"];
  check = {
    context ? "COMPOSED",
    defs,
    enabled ? defaultRuntimes,
    expect,
  }: let
    config = evaluate context enabled defs;
    delivered = harness.deliveredFiles config;
    wanted =
      if expect == "composed"
      then {source = "${config.ai.internal._generatedTree}/${path}";}
      else expect;
    claimed = (config.ai.claims.path.${path} or []) == ["internal"];
    listed = builtins.elem path config.ai.deliveredPaths;
  in
    claimed
    && (
      if expect == "absent"
      then !(delivered ? ${path}) && !listed
      else
        delivered.${path} or null
        == wanted // {method = "ro";}
        && config.ai.files.${path}.format == "markdown"
        && listed
    );
  legacyLedgers = result: result.config.ai.legacyLedgers;
  holds = harness.checkRows "shared AGENTS.md" (lib.mapAttrs (_: check) cases
    // {
      "divergent equal-priority runtime text fails the content merge" = harness.rejectsChange (defs: (evaluate "COMPOSED" defaultRuntimes defs).ai.files.${path}.content.text) rec {
        valid.codex.content.text = "CODEX";
        invalid = valid // {kiro.content.text = "KIRO";};
        expected = "CODEX";
      };
      "legacy ledger is declared on devenv even without contributors" = builtins.elem ledger (legacyLedgers (harness.evalDevenv {}));
      "legacy ledger never imports from Home Manager's state" = !(builtins.elem ledger (legacyLedgers (harness.evalHm {})));
    });

  # Ported from module-delivery-devenv-excludes-delivered-paths-from-treefmt.
  excludeFixture = treefmtEnable:
    harness.evalDevenv {
      ai.claude = {
        enable = true;
        files = {
          ".claude/hooks/raw-probe".content.source = ./fixtures/tree/bin/tool;
          ".claude/settings.json".enable = false;
        };
        rules.probe.text = "probe";
        skills.probe = ./fixtures/probe-skill;
      };
      treefmt.enable = treefmtEnable;
    };
  excluded = excludeFixture true;
  expectedPaths = [
    ".claude/hooks/raw-probe"
    ".claude/rules/probe.md"
    ".claude/skills/probe/**"
  ];
  pathHolds = harness.checkRows "delivered paths" {
    "disabled treefmt leaves its exclusions empty" = (excludeFixture false).config.treefmt.config.settings.global.excludes == [];
    "Home Manager does not receive treefmt options" = !((harness.evalHm {}).config ? treefmt);
    "treefmt excludes both leaves and the recursive glob but skips disabled settings" = excluded.config.treefmt.config.settings.global.excludes == expectedPaths;
  };
in {
  checks = {
    ai-module-delivered-paths = assert pathHolds;
      pkgs.runCommandLocal "ai-module-delivered-paths" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        printf 'PASS: devenv treefmt excludes every delivered path\n' > "$out"
      '';
    ai-module-shared-agents-md = assert holds;
      pkgs.runCommandLocal "ai-module-shared-agents-md" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        printf 'PASS: one composer claims AGENTS.md; runtime entries arbitrate by priority\n' > "$out"
      '';
  };
}
