# The shared repository AGENTS.md on devenv, through every repository module.
# Its composer (`ai.internal`) is the path's one claimant; a runtime's
# `files."AGENTS.md"` forwards unclaimed and arbitrates by module priority:
# agreeing definitions merge, an ordinary one replaces the composition,
# `enable = false` suppresses it, divergent ones at one priority fail, and a
# dormant runtime's entry is ignored. A replacing source is never read during
# evaluation. The old writer's ledger is declared even when nothing
# contributes, and `ai.deliveredPaths` is what the devenv treefmt run excludes.
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
  unbuildable = pkgs.runCommand "shared-agents-md-must-not-build" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    exit 1
  '';
  same = {
    content.text = "SAME";
    format = "markdown";
  };
  # `expect`: "composed", "absent", "fails", or the delivered content.
  cases = {
    agreeing = {
      defs = lib.genAttrs ["codex" "kimchi" "kiro"] (_: same);
      expect.text = "SAME";
    };
    agreeing-with-composer = {
      defs.codex = {
        format = lib.mkDefault "markdown";
        method = lib.mkDefault "ro";
      };
      expect = "composed";
    };
    composed = {
      defs = {};
      expect = "composed";
    };
    consumer-only = {
      context = null;
      defs = lib.genAttrs ["codex" "kimchi"] (_: same);
      enabled = ["codex" "kimchi"];
      expect.text = "SAME";
    };
    divergent = {
      defs = {
        codex.content.text = "CODEX";
        kiro.content.text = "KIRO";
      };
      expect = "fails";
    };
    dormant = {
      defs.kiro.content.text = "DORMANT";
      enabled = ["codex"];
      expect = "composed";
    };
    replacing-source = {
      defs.kiro.content.source = unbuildable;
      expect.source = "${unbuildable}";
    };
    replacing-text = {
      defs.codex.content.text = "CODEX";
      expect.text = "CODEX";
    };
    suppressing = {
      defs.kiro.enable = false;
      expect = "absent";
    };
    suppressing-a-replacement = {
      defs = {
        codex.content.text = "CODEX";
        kiro.enable = false;
      };
      expect = "absent";
    };
  };
  check = name: {
    context ? "COMPOSED",
    defs,
    enabled ? ["codex" "kimchi" "kiro"],
    expect,
  }: let
    inherit
      (harness.evalDevenv (lib.foldl' lib.recursiveUpdate (lib.optionalAttrs (context != null) {ai.context.text = context;}) (
        map (runtime: harness.setEnable runtime true) enabled
        ++ lib.mapAttrsToList (runtime: entry: {ai.${runtime}.files.${path} = entry;}) defs
      )))
      config
      ;
    delivered = harness.deliveredFiles config;
    wanted =
      if expect == "composed"
      then {source = "${config.ai.internal._generatedTree}/${path}";}
      else expect;
    shape = lib.optional (config.ai.claims.path.${path} or [] != ["internal"]) "claimant";
    outcome =
      if expect == "fails"
      then lib.optional (builtins.tryEval (builtins.deepSeq delivered.${path} true)).success "evaluates"
      else if expect == "absent"
      then lib.optional (delivered ? ${path} || builtins.elem path config.ai.deliveredPaths) "delivered" ++ shape
      else
        lib.optional (delivered.${path} or null != wanted // {method = "ro";}) "content"
        ++ lib.optional (config.ai.files.${path}.format != "markdown") "format"
        ++ lib.optional (!builtins.elem path config.ai.deliveredPaths) "delivered paths"
        ++ shape;
  in
    map (failure: "${name}: ${failure}") outcome;
  noContributor = harness.evalDevenv {};
  failures =
    lib.concatLists (lib.mapAttrsToList check cases)
    ++ lib.optional (!builtins.elem ledger noContributor.config.ai.legacyLedgers) "legacy ledger without contributors"
    ++ lib.optional (builtins.elem ledger (harness.evalHm {}).config.ai.legacyLedgers) "legacy ledger on Home Manager";

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
  pathFailures =
    lib.optional (excluded.config.ai.deliveredPaths != expectedPaths) "deliveredPaths"
    ++ lib.optional (excluded.config.treefmt.config.settings.global.excludes != expectedPaths) "treefmt excludes"
    ++ lib.optional ((excludeFixture false).config.treefmt.config.settings.global.excludes != []) "treefmt disabled"
    ++ lib.optional ((harness.evalHm {}).config ? treefmt) "Home Manager treefmt";
in {
  checks = {
    ai-module-delivered-paths = assert lib.assertMsg (pathFailures == []) "delivered paths: ${lib.concatStringsSep ", " pathFailures}";
      pkgs.runCommandLocal "ai-module-delivered-paths" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        printf 'PASS: devenv treefmt excludes every delivered path\n' > "$out"
      '';
    ai-module-shared-agents-md = assert lib.assertMsg (failures == []) "shared AGENTS.md: ${lib.concatStringsSep ", " failures}";
      pkgs.runCommandLocal "ai-module-shared-agents-md" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        printf 'PASS: one composer claims AGENTS.md; runtime entries arbitrate by priority\n' > "$out"
      '';
  };
}
