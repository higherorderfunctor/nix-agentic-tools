# Each runtime effect of ai.programs.git-worktrees, on both backends.
{
  lib,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;
  runtimes = ["claude" "codex" "kimchi" "kiro"];
  onBoth = config: predicate: lib.all (evaluate: predicate (evaluate config).config) [evalHm evalDevenv];
  entry = config: runtime: config.ai.${runtime}.extraSystemPrompt.git-worktrees or null;
  delivered = config: runtime: let
    value = entry config runtime;
  in
    if value != null && value.enable
    then value.text
    else null;
  enabled = extra: lib.recursiveUpdate {ai.programs.git-worktrees.enable = true;} extra;
in {
  checks = {
    # Every contribution is a default a consumer definition replaces.
    module-git-worktrees-consumer-wins = mkTest "git-worktrees-consumer-wins" (
      onBoth (enabled {
        ai = {
          claude.extraSystemPrompt.git-worktrees.enable = false;
          codex.extraSystemPrompt.git-worktrees.text = "own";
          kiro.tweaks = {
            relativeFileCheckPaths = false;
            stripVendorWorktreeSteering = false;
          };
        };
      }) (config:
        delivered config "claude"
        == null
        && delivered config "codex" == "own"
        && !config.ai.kiro.tweaks.stripVendorWorktreeSteering
        && !config.ai.kiro.tweaks.relativeFileCheckPaths)
    );

    module-git-worktrees-default-disabled = mkTest "git-worktrees-default-disabled" (
      onBoth {} (config:
        lib.all (runtime: delivered config runtime == null) runtimes
        && !config.ai.kiro.tweaks.stripVendorWorktreeSteering
        && !config.ai.kiro.tweaks.relativeFileCheckPaths)
    );

    # The default protocol reaches every supported runtime's own pool with
    # `{location}` rendered; `{repo}` remains available to the runtime.
    module-git-worktrees-enable = mkTest "git-worktrees-enable" (
      onBoth (enabled {}) (config:
        lib.all (runtime: let
          text = delivered config runtime;
        in
          text
          != null
          && lib.hasInfix "../{repo}-worktrees" text
          && !(lib.hasInfix "{location}" text))
        runtimes
        && config.ai.kiro.tweaks.stripVendorWorktreeSteering
        && config.ai.kiro.tweaks.relativeFileCheckPaths)
    );

    module-git-worktrees-protocol-disabled = mkTest "git-worktrees-protocol-disabled" (
      onBoth (enabled {
        ai.programs.git-worktrees.protocol =
          lib.genAttrs
          ["base" "cleanup" "draft" "isolate" "protect" "request"]
          (_: {enable = false;});
      }) (config: lib.all (runtime: delivered config runtime == null) runtimes)
    );

    module-git-worktrees-protocol-keys = mkTest "git-worktrees-protocol-keys" (
      onBoth (enabled {
        ai.programs.git-worktrees.protocol = {
          audit.text = "AUDIT";
          base.text = "BASE";
          cleanup.text = "CLEANUP";
          draft.enable = false;
          isolate.text = "ISOLATE {location}";
          protect.text = "PROTECT";
          request.text = "REQUEST";
          sign.text = "Sign every commit.";
        };
      }) (config:
        lib.all (runtime:
          delivered config runtime == "ISOLATE ../{repo}-worktrees\n\nBASE\n\nREQUEST\n\nPROTECT\n\nCLEANUP\n\nAUDIT\n\nSign every commit.")
        runtimes)
    );

    # A `source` file replaces the shipped text; its trailing newline is
    # dropped, so the entry keeps single blank-line separators.
    module-git-worktrees-protocol-source = mkTest "git-worktrees-protocol-source" (
      onBoth (enabled {
        ai.programs.git-worktrees.protocol.draft.source = ./draft.txt;
      }) (config:
        lib.all (runtime: let
          text = delivered config runtime;
        in
          lib.hasInfix "\n\nDraft fixture: open every request as a draft.\n\n" text
          && !(lib.hasInfix "Open pull or merge requests as drafts." text))
        runtimes)
    );

    # A runtime override replaces one leaf for that runtime only.
    module-git-worktrees-runtime-overrides = mkTest "git-worktrees-runtime-overrides" (
      onBoth (enabled {
        ai.programs.git-worktrees.runtimes = {
          codex.enable = false;
          kimchi.protocol.custom.text = "Worktrees: {location}";
          kiro.enable = false;
        };
      }) (config:
        delivered config "codex"
        == null
        && delivered config "kimchi" == "Worktrees: ../{repo}-worktrees"
        && delivered config "claude" != null
        && !config.ai.kiro.tweaks.stripVendorWorktreeSteering)
    );
  };
}
