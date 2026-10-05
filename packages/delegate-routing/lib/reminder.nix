# The per-turn delegate-routing reminder: a first-person standing request
# injected on every UserPromptSubmit. The wording is load-bearing; read
# packages/claude-code/docs/heron-brook-clamp.md before changing it.
{
  lib,
  pkgs,
}: let
  shellStrict = import ../../../config/shell-strict.nix;
  # One executable per payload, so every runtime's hook command is a bare
  # store path with no shell parsing. The payload is serialized at eval time.
  printer = name: payload:
    lib.getExe (pkgs.writeShellApplication {
      inherit name;
      inherit (shellStrict) bashOptions;
      extraShellCheckFlags = shellStrict.shellcheckFlags;
      runtimeInputs = [pkgs.coreutils];
      text = ''
        ${shellStrict.shoptHeader}
        cat -- ${pkgs.writeText "${name}-payload" payload}
      '';
    });
  # Claude, Codex and Kimchi read `hookSpecificOutput.additionalContext` from
  # a UserPromptSubmit hook's JSON stdout.
  additionalContext = text:
    printer "delegate-routing-reminder" (builtins.toJSON {
      hookSpecificOutput = {
        hookEventName = "UserPromptSubmit";
        additionalContext = text;
      };
    });
in {
  defaultText = "Standing request from me, the user: you may use subagents (the Agent/Task tool), workflows and deep research whenever they fit; before you delegate, load the delegate-routing skill and follow its always-on guidance.";

  # runtime -> reminder text -> definitions under `ai.<runtime>`.
  hooks =
    lib.genAttrs ["claude" "codex" "kimchi"] (_: text: {
      hooks.UserPromptSubmit = [{hooks = [{command = additionalContext text;}];}];
    })
    // {
      # Kiro's v3 hooks take plain stdout as added context.
      kiro = text: {
        hooks.delegate-routing-reminder = {
          action.command = printer "delegate-routing-reminder-text" text;
          description = "Per-turn delegate-routing reminder";
          trigger = "UserPromptSubmit";
        };
      };
    };
}
