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
  # The generated settings tree declares every key, unset ones as null.
  claudeWorktree = config: config.ai.claude.native.settings.worktree;
  enabled = extra: lib.recursiveUpdate {ai.programs.git-worktrees.enable = true;} extra;
in {
  checks = {
    module-git-worktrees-claude-absolute-location = mkTest "git-worktrees-claude-absolute-location" (
      onBoth (enabled {ai.programs.git-worktrees.location = "~/worktrees";}) (config:
        config.ai.claude.native.settings.worktree.location
        == "~/worktrees"
        && lib.hasInfix "`~/worktrees`" (delivered config "codex"))
    );

    # Every contribution is a default a consumer definition replaces.
    module-git-worktrees-consumer-wins = mkTest "git-worktrees-consumer-wins" (
      onBoth (enabled {
        ai = {
          claude.extraSystemPrompt.git-worktrees.enable = false;
          codex.extraSystemPrompt.git-worktrees.text = "own";
          kiro.tweaks.stripVendorWorktreeSteering = false;
        };
      }) (config:
        delivered config "claude"
        == null
        && delivered config "codex" == "own"
        && !config.ai.kiro.tweaks.stripVendorWorktreeSteering)
    );

    module-git-worktrees-default-disabled = mkTest "git-worktrees-default-disabled" (
      onBoth {} (config:
        lib.all (runtime: delivered config runtime == null) runtimes
        && claudeWorktree config == null
        && !config.ai.kiro.tweaks.stripVendorWorktreeSteering)
    );

    # The default protocol reaches every supported runtime's own pool with
    # `{location}` rendered. The default location has a
    # `{repo}` placeholder, which Claude's `worktree.location` cannot express.
    module-git-worktrees-enable = mkTest "git-worktrees-enable" (
      onBoth (enabled {}) (config:
        lib.all (runtime: let
          text = delivered config runtime;
        in
          text
          != null
          && lib.hasInfix "`../{repo}-worktrees`" text
          && !(lib.hasInfix "{location}" text))
        runtimes
        && claudeWorktree config == null
        && config.ai.kiro.tweaks.stripVendorWorktreeSteering)
    );

    # A runtime override replaces one leaf for that runtime only.
    module-git-worktrees-runtime-overrides = mkTest "git-worktrees-runtime-overrides" (
      onBoth (enabled {
        ai.programs.git-worktrees.runtimes = {
          codex.enable = false;
          kimchi.protocol.text = "Worktrees: {location}";
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
