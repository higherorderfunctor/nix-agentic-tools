# A per-turn workflow reminder, delivered as a `UserPromptSubmit` hook.
#
# ── Why a hook and not more steering ────────────────────────────────────────
# When `workflowsEnabled` is set the engine already appends its own
# workflow-orchestration steering (minified since 2.27.1; formerly
# `workflows_default`) to the system prompt, and that block is emphatic
# ("always delegate implementation to workflows", "Do NOT read source files
# yourself"). It is also ~15.5k characters / ~3.9k tokens, and it lands in
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
# turn would cost ~3.9k tokens per turn -- roughly 195k tokens across a 50-turn
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
  # the shape to reach for, and lets msg0 supply the detail. Both pointers match
  # the 2.27.1 steering: delegation is ONE `run_workflow` call carrying a
  # `workflowPrompt` brief (`workflow-creator` runs inside it), and the reviewer
  # is the last step of the loop.
  #
  # The worktree paragraph is the ONE deliberate exception, because there the
  # vendor text is WRONG for us rather than merely distant. 2.27.1 tells the
  # generated workflow to `git worktree add .worktrees/<name> -b <branch>
  # mainline`, i.e. INSIDE the checkout, and to rebase onto and fast-forward
  # `mainline`. A worktree nested in the checkout is re-entered and
  # re-evaluated by direnv/devenv under the parent, which blows up their
  # caches; that is why worktrees belong outside the checkout the LLM runs in.
  # And `mainline` is not every repository's trunk. msg0 is frozen and replayed
  # byte-for-byte, so no pointer can repair it; only later, contradicting text
  # can, which is the one thing this hook's POSITION buys. Do not delete it as
  # drift: it is a CORRECTION, not a restatement. It names no repository's
  # paths because it ships to every consumer.
  #
  # The orchestrator never creates the worktree itself (the steering says the
  # workflow owns that setup), so the correction steers the `workflowPrompt`
  # BRIEF. It also has to carry the fileCheck rule: since 2.27.1 the
  # instruction to interpolate `{{worktree_path}}/...` into every path,
  # `fileCheck.path` included, lives in the workflow-creator prompt, which the
  # orchestrator can reach only through that brief. A sibling worktree makes
  # such a path resolve outside the workspace roots, and the engine rejects
  # the run at launch (`additionalDirectories` comes from the ACP session
  # request, so the model cannot widen the roots).
  #
  # Retire it when the vendor text stops nesting worktrees and stops
  # interpolating fileCheck paths; the vendorAnchors entries below make the
  # drift check fail when either text moves.
  defaultText = ''
    <workflow_orchestration_reminder>
    Before answering: if this turn asks you to implement a feature, fix a bug,
    investigate an issue, or change code, delegate it to a workflow rather than
    doing it inline, with a single `run_workflow` call carrying a
    `workflowPrompt` brief. Do not pre-read source files to "understand the
    problem" first -- that is the workflow's job.

    For anything a reviewer should sign off on, use the repeat loop: `wf-coder`
    then `semantic_reviewer`, in that order, with a stopCondition on the review
    verdict file. The reviewer is always last.

    When work needs a worktree, the generated workflow creates it, so put the
    location in your `workflowPrompt` brief: never inside the workspace,
    whatever the default `.worktrees/<name>` says. Use the location the
    repository's own instructions (AGENTS.md, steering) give for a worktree
    outside the workspace; if they give none, use a sibling directory of the
    checkout. Name the repository's actual default branch in the brief, not
    `mainline`. Also tell it that every `fileCheck.path` (review verdict, stop
    condition), both where a step writes the file and where the check reads
    it, is a RELATIVE path inside the workspace, such as
    `.agents/tasks/review.json`, never `{{worktree_path}}/...`. The engine
    rejects the run at launch when that path resolves outside the workspace,
    and a sibling worktree always does.

    Conversation, status, and follow-up questions are yours to answer directly;
    substantive work is not.
    </workflow_orchestration_reminder>
  '';

  # Vendor sentences `defaultText` is written against. The
  # kiro-workflows-steering-drift check extracts the steering from the pinned
  # release's real engine bundle and fails when any of these is gone, so a
  # vendor rewrite under the reminder turns the kiro-cli update PR red instead
  # of leaving the reminder pointing at, or correcting, text that moved.
  # `paragraph` names what to re-review when the check fires. Anchors default to
  # the extracted steering; `scope = "bundle"` matches the raw engine bundle
  # instead, for text that lives elsewhere in it (the workflow-creator prompt,
  # the engine's errors, the agent registries). Bundle-scoped text must contain
  # no backtick, because the raw template literals escape it.
  vendorAnchors = [
    {
      paragraph = "delegation (one run_workflow call carrying a workflowPrompt brief)";
      text = "create and launch the workflow with a single `run_workflow` call carrying a `workflowPrompt` brief";
    }
    {
      paragraph = "review loop (the reviewer is always last)";
      text = "The reviewer is always the last step";
    }
    {
      paragraph = "worktree correction (nested `.worktrees/` and `mainline`)";
      text = "`git worktree add .worktrees/<name> -b <branch> mainline`";
    }
    {
      paragraph = "worktree correction (nested `.worktrees/` and `mainline`)";
      text = "rebases the branch onto `mainline` and fast-forwards `mainline`";
    }
    {
      paragraph = "worktree correction (fileCheck stays workspace-relative)";
      scope = "bundle";
      text = "for every file a step reads, writes, or commits";
    }
    {
      paragraph = "worktree correction (fileCheck stays workspace-relative)";
      scope = "bundle";
      text = "outside the allowed workspace roots";
    }
    {
      paragraph = "review loop (agent names)";
      scope = "bundle";
      text = ''["wf-coder",'';
    }
    {
      paragraph = "review loop (agent names)";
      scope = "bundle";
      text = ''["semantic_reviewer",'';
    }
  ];
in {
  inherit defaultText vendorAnchors;

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

        skip_reminder() {
          printf 'WARNING: ai.kiro.workflowReminder.includeVendorSteering: %s; vendor reminder was not delivered\n' "$1" >&2
          exit 0
        }

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
        ' "$data_dir/kas" ${lib.escapeShellArg cliVersion} 2>/dev/null)" || skip_reminder "no compatible engine bundle"

        # A hook that fails must not break the turn, so every failure path here
        # exits 0 with an option-named stderr warning. An absent reminder must
        # be visible without making UserPromptSubmit fail the session.
        bundle="''${kas}node_modules/@kiro/agent/dist/server/acp-server.js"
        [ -f "$bundle" ] || skip_reminder "engine script is missing"

        cache="$cache_root/$("$coreutils"/bin/basename "''${kas%/}").md"
        if [ ! -s "$cache" ]; then
          "$coreutils"/bin/mkdir -p "$cache_root" 2>/dev/null || skip_reminder "cannot create reminder cache"
          tmp="$("$coreutils"/bin/mktemp "$cache_root/.extract.XXXXXX" 2>/dev/null)" || skip_reminder "cannot create reminder temporary file"
          # The extractor's own stderr is the diagnosis (which anchor, how many
          # matches), so it is captured into the warning rather than discarded:
          # a bare "extraction failed" sends the reader to re-derive what the
          # extractor already knew. Redirection order matters: stderr goes to
          # the capture, stdout to the temporary file.
          if reason="$("$python" "$extract" "$bundle" 2>&1 > "$tmp")" && [ -s "$tmp" ]; then
            "$coreutils"/bin/mv "$tmp" "$cache" 2>/dev/null || skip_reminder "cannot publish reminder cache"
          else
            # Best effort, and deliberately so: cleanup failing must not turn
            # this hook into a non-zero exit under errexit.
            "$coreutils"/bin/rm -f "$tmp" 2>/dev/null || :
            reason="''${reason//$'\n'/ }"
            skip_reminder "vendor steering extraction failed: ''${reason:-extractor printed no text}"
          fi
        fi

        # Read FIRST, print second. Printing the opening tag before the read
        # meant a failed read exited 0 having already emitted
        # `<workflow_orchestration_reminder>` with no body and no closing tag,
        # injecting a malformed block into the prompt instead of nothing.
        if ! body="$("$coreutils"/bin/cat "$cache" 2>/dev/null)"; then
          skip_reminder "cannot read reminder cache"
        fi
        printf '%s\n%s\n%s\n' \
          "<workflow_orchestration_reminder>" \
          "$body" \
          "</workflow_orchestration_reminder>"
      '';
    };
}
