# A per-turn workflow reminder, delivered as a `UserPromptSubmit` hook.
#
# ── Why a hook and not more steering ────────────────────────────────────────
# When `workflowsEnabled` is set the engine already appends its own
# `workflows_default` steering to the system prompt, and that block is emphatic
# ("always delegate implementation to workflows", "Do NOT read source files
# yourself"). It is also ~19.3k characters / ~4.8k tokens, and it lands in
# **msg0**, which is computed on the FIRST turn and thereafter replayed
# byte-for-byte. So the instruction never decays and adding more steering adds
# nothing -- a second copy would sit in the same place, competing with the same
# context.
#
# What decays is ATTENTION: one block near the top of a growing conversation
# loses out to everything since, which is exactly the reported symptom (the
# model elects workflows while you are talking about workflows, and stops when
# you stop). A `UserPromptSubmit` hook lands as a CONTEXT message beside each
# prompt, so it buys POSITION rather than content.
#
# That is why the default reminder is short. Re-injecting the vendor block every
# turn would cost ~4.8k tokens per turn -- roughly 240k tokens across a 50-turn
# session -- to repeat text the model already has. `includeVendorSteering`
# exists for anyone who measures otherwise, and is off by default.
{
  lib,
  pkgs,
}: let
  extractor = ./kiro-workflows-steering.py;

  # Deliberately a POINTER, not a summary. The vendor block is already in msg0;
  # restating its rules here would fork a second source of truth that goes stale
  # against the engine on the next bump. This names the decision to re-open and
  # the shape to reach for, and lets msg0 supply the detail.
  defaultText = ''
    <workflow_orchestration_reminder>
    Before answering: if this turn asks you to implement a feature, fix a bug,
    investigate an issue, or change code, delegate it to a workflow rather than
    doing it inline. Use `workflow-creator` to generate the JSON, then
    `run_workflow`. Do not pre-read source files to "understand the problem"
    first -- that is the workflow's job.

    For anything a reviewer should sign off on, use the repeat loop: `wf-coder`
    then `semantic_reviewer`, in that order, with a stopCondition on the review
    verdict file. The reviewer is always last.

    Conversation, status, and follow-up questions are yours to answer directly;
    substantive work is not.
    </workflow_orchestration_reminder>
  '';
in {
  inherit defaultText;

  # Command-mode reminder for `includeVendorSteering = true`: the vendor text
  # cannot be read at eval time (the engine bundle is unpacked from the binary
  # at runtime and is never in the nix store), so it is extracted on first use
  # and cached. Keyed by bundle directory, so a CLI upgrade re-extracts.
  mkVendorReminder = {cliVersion}:
    pkgs.writeShellApplication {
      name = "kiro-workflow-reminder";
      bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
      runtimeInputs = [];
      text = ''
        shopt -s inherit_errexit 2>/dev/null || :

        # Absolute store paths: a hook subprocess inherits whatever environment
        # the engine hands it, which is not guaranteed to carry a usable PATH
        # (nix-standards).
        coreutils=${lib.escapeShellArg pkgs.coreutils}
        python=${lib.escapeShellArg (lib.getExe pkgs.python3)}
        extract=${lib.escapeShellArg extractor}

        data_dir="''${KIRO_DATA_DIR:-''${XDG_DATA_HOME:-$HOME/.local/share}/kiro-cli}"
        cache_root="''${XDG_CACHE_HOME:-$HOME/.cache}/nix-agentic-tools/kiro-workflow-steering"

        # Same resolver rule as the identity materializer: highest bundle
        # version not exceeding the CLI version. Exact match is wrong because
        # the embedded engine may LAG the CLI, and glob order is wrong because
        # lexical-first silently selects a bundle many releases behind.
        kas="$("$python" -c '
        import os, sys
        root, cli = sys.argv[1], sys.argv[2]
        def key(v):
            return tuple(int(p) if p.isdigit() else -1 for p in v.split("."))
        try:
            names = os.listdir(root)
        except OSError:
            sys.exit(1)
        candidates = []
        for n in names:
            p = os.path.join(root, n)
            if os.path.isdir(p) and "-" in n and key(n.split("-", 1)[0]) <= key(cli):
                candidates.append((key(n.split("-", 1)[0]), p))
        if not candidates:
            sys.exit(1)
        sys.stdout.write(max(candidates)[1] + "/")
        ' "$data_dir/kas" ${lib.escapeShellArg cliVersion} 2>/dev/null)" || exit 0

        # A hook that fails must not break the turn, so every failure path here
        # exits 0 with no output. An absent reminder degrades elicitation; a
        # failing UserPromptSubmit hook degrades the session.
        bundle="''${kas}node_modules/@kiro/agent/dist/server/acp-server.js"
        [ -f "$bundle" ] || exit 0

        cache="$cache_root/$("$coreutils"/bin/basename "''${kas%/}").md"
        if [ ! -s "$cache" ]; then
          "$coreutils"/bin/mkdir -p "$cache_root"
          tmp="$("$coreutils"/bin/mktemp "$cache_root/.extract.XXXXXX")"
          if "$python" "$extract" "$bundle" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
            "$coreutils"/bin/mv "$tmp" "$cache"
          else
            "$coreutils"/bin/rm -f "$tmp"
            exit 0
          fi
        fi

        printf '%s\n' "<workflow_orchestration_reminder>"
        "$coreutils"/bin/cat "$cache"
        printf '%s\n' "</workflow_orchestration_reminder>"
      '';
    };
}
