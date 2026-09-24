{lib, ...}: let
  # ── The unrecognized-key guard on the freeform nativeSettings tail ────
  #
  # These four cases exist because the guard is built ONCE
  # (`nativeSettingsAssertions` in mkClaude.nix) and consumed by BOTH
  # projections' mkMerge lists. Nothing else in this file forces
  # `config.assertions` for claude, so without them the check would ship to CI
  # never having been evaluated on either backend.
  #
  # Each case runs on HM and devenv and requires the SAME verdict from both:
  # the two backends write the same settings tree, so a divergence is a
  # config-parity bug by definition.
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

  # Keys the binary declares, INCLUDING the three container shapes the check
  # has to stay permissive about: a freeform record (`env.<VAR>`), a
  # user-keyed map with a typed value (`modelPricing.overrides.<model-id>`),
  # and the hooks matcher-block array (`hooks.<Event>[]`).
  claudeKnownKeysCfg = {
    ai.claude = {
      enable = true;
      nativeSettings = {
        env.MY_VAR = "1";
        hooks.PreToolUse = [{matcher = "Bash";}];
        modelPricing.overrides."claude-opus-5".input = 1.0;
        permissions.defaultMode = "acceptEdits";
      };
    };
  };

  # A typo three levels inside `permissions`. Upstream tolerates extra keys
  # there and silently ignores them, which is exactly why this module does not.
  claudeNestedTypoCfg = {
    ai.claude = {
      enable = true;
      nativeSettings.permissions.alow = ["Read"];
    };
  };

  # ── built-in Claude hook helpers ─────────────────────────────────
  # Every built-in hook's handler command is a /nix/store path, so match on the
  # derivation name rather than on an exact string.
  handlerCommands = blocks:
    lib.concatMap (b: map (h: h.command) b.hooks) blocks;
  hasClampHook = blocks:
    builtins.any (lib.hasInfix "claude-delegation-clamp") (handlerCommands blocks);
  hasGuardHook = blocks:
    builtins.any (lib.hasInfix "claude-memory-collision-guard") (handlerCommands blocks);
in {
  inherit claudeAssertionFails claudeAssertions claudeAssertionsPass claudeKnownKeysCfg claudeNestedTypoCfg handlerCommands hasClampHook hasGuardHook;
}
