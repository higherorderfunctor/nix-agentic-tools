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
  kiroReminder = text:
    lib.getExe (strictShellApplication {
      name = "delegate-routing-reminder-kiro";
      text = ''
        session_id="$(${pkgs.jq}/bin/jq -ers '
          select(length == 1) | .[0].session_id
          | select(test("\\Asess_[A-Za-z0-9_-]+\\z"))
        ' 2>/dev/null || :)"
        # Reject missing IDs and path traversal/glob characters before globbing.
        if [[ -n "$session_id" ]]; then
          # Kiro's engine session root follows HOME, not the client-only KIRO_HOME.
          for session in "$HOME"/.kiro/sessions/*/"$session_id"/session.json; do
            if ${pkgs.jq}/bin/jq -es '
              length == 1 and (.[0]._meta.kiro.workflow | type == "object")
            ' "$session" >/dev/null 2>&1; then
              exit 0
            fi
          done
        fi
        exec ${printer "delegate-routing-reminder-text" text}
      '';
    });
in {
  # Wording grants the standing opt-in for delegation surfaces; see heron-brook-clamp.md.
  defaultText = "Standing request from me, the user: you may use subagents, workflows, deep research and delegates whenever they fit; use the delegate-routing skill to size their model and effort.";

  # Definitions under ai.<runtime>; Kiro consumes plain stdout.
  hooks =
    lib.genAttrs ["claude" "codex" "kimchi"] (_: text: {
      hooks.UserPromptSubmit = [{hooks = [{command = additionalContext text;}];}];
    })
    // {
      kiro = text: {
        hooks.delegate-routing-reminder = {
          action.command = kiroReminder text;
          description = "Per-turn delegate-routing reminder";
          trigger = "UserPromptSubmit";
        };
      };
    };
}
