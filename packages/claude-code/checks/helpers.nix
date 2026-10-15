{lib, ...}: let
  # Both backends inspect the same filtered settings tree. Keep module
  # assertions separate: spelling diagnostics must never become refusals.
  claudeAssertions = ev:
    lib.filter (a: lib.hasPrefix "ai.claude." a.message) ev.config.assertions;

  # Non-empty is load-bearing: `lib.all` over an empty list is `true`, so a
  # guard that stopped being wired at all would read as a pass.
  claudeAssertionsPass = ev: let
    found = claudeAssertions ev;
  in
    found != [] && lib.all (a: a.assertion) found;

  claudeAssertionFails = infix: ev:
    builtins.any
    (a: !a.assertion && lib.hasInfix infix a.message)
    (claudeAssertions ev);

  claudeSettingsWarnings = ev:
    lib.filter (warning:
      lib.hasPrefix "ai.claude.native.settings" warning
      || lib.hasPrefix "ai.claude.allowUnrecognizedSettings" warning)
    ev.config.warnings;

  # Keys the binary declares, INCLUDING the three container shapes the check
  # has to stay permissive about: a freeform record (`env.<VAR>`), a
  # user-keyed map with a typed value (`modelPricing.overrides.<model-id>`),
  # and the hooks matcher-block array (`hooks.<Event>[]`).
  claudeKnownKeysCfg = {
    ai.claude = {
      enable = true;
      native.settings = {
        env.MY_VAR = "1";
        hooks.PreToolUse = [{matcher = "Bash";}];
        modelPricing.overrides."claude-opus-5".input = 1.0;
        permissions.defaultMode = "acceptEdits";
      };
    };
  };

  # A typo three levels inside `permissions`. Upstream tolerates extra keys
  # there and silently ignores them, so the module warns while preserving them.
  claudeNestedTypoCfg = {
    ai.claude = {
      enable = true;
      native.settings.permissions.alow = ["Read"];
    };
  };

  # ── built-in Claude hook helpers ─────────────────────────────────
  # Every built-in hook's handler command is a /nix/store path, so match on the
  # derivation name rather than on an exact string.
  handlerCommands = blocks:
    lib.concatMap (b: map (h: h.command) b.hooks) blocks;
  hasGuardHook = blocks:
    builtins.any (lib.hasInfix "claude-memory-collision-guard") (handlerCommands blocks);
in {
  inherit claudeAssertionFails claudeAssertions claudeAssertionsPass claudeKnownKeysCfg claudeNestedTypoCfg claudeSettingsWarnings handlerCommands hasGuardHook;
}
