# One per-turn standing request, with the same payload for every harness.
{
  lib,
  pkgs,
}: let
  strictShellApplication = import ../../../lib/strict-shell-application.nix pkgs;
  printer = name: payload:
    lib.getExe (strictShellApplication {
      inherit name;
      text = ''
        ${pkgs.coreutils}/bin/cat -- ${pkgs.writeText "${name}-payload" payload} || :
      '';
    });
  additionalContext = text:
    printer "delegate-routing-reminder" (builtins.toJSON {
      hookSpecificOutput = {
        additionalContext = text;
        hookEventName = "UserPromptSubmit";
      };
    });
in {
  # Wording grants explicit workflow opt-in; see heron-brook-clamp.md.
  defaultText = "Standing request from me, the user: you may use subagents, workflows and delegates whenever they fit; use the delegate-routing skill to size their model and effort.";

  # Definitions under ai.<runtime>; Kiro consumes plain stdout.
  hooks =
    lib.genAttrs ["claude" "codex" "kimchi"] (_: text: {
      hooks.UserPromptSubmit = [{hooks = [{command = additionalContext text;}];}];
    })
    // {
      kiro = text: {
        hooks.delegate-routing-reminder = {
          action.command = printer "delegate-routing-reminder-text" text;
          description = "Per-turn delegate-routing reminder";
          trigger = "UserPromptSubmit";
        };
      };
    };
}
