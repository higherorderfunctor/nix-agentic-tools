# Stacked-workflow router: the always-on rule contributed to `ai.rules`.
# Shared by the HM (user-global) and devenv (project) modules so the router
# content stays single-source.
#
# This rule is ALWAYS-LOADED in every ecosystem (`matcher = null` → Kiro
# `inclusion: always`, Claude no `paths:` key), so its size is a per-turn tax on
# every session in every consumer. It is therefore deliberately kept to the ONE
# thing a skill description cannot express, and holds neither of these:
#
#   - NOT an operation → skill routing table. That duplicates the skill
#     descriptions, which are themselves resident: Claude and Kiro both surface
#     `name` + `description` for every installed skill and load the body on
#     demand. Measured 2026-07-31 — the 9-row table was 1700 of this fragment's
#     2205 bytes, against 2670 bytes of stack-* frontmatter already in context
#     restating the same "use INSTEAD of" mapping nearly verbatim.
#   - NOT a candidate for Kiro `inclusion: auto`. `auto` is description-matched
#     by the same matcher that fires skills, so it cannot fire in the case this
#     rule exists for: the model shelling out to `git rebase -i` without ever
#     considering a skill IS the case where description matching already failed.
#
# A PreToolUse hook was evaluated as a deterministic replacement and REJECTED.
# The skills' own bodies run `git absorb` (stack-fix), `git rebase -i` and
# `git reset HEAD^` (stack-split), and `git reset --soft` / `git commit --fixup`
# (stack-plan) — every command the old table named as a thing to use a skill
# INSTEAD of. A command matcher therefore fires mostly on CORRECT behavior:
# `deny` breaks the skills outright, `ask` prompts inside every correct run. And
# PreToolUse sees only `tool_name` + `tool_input`, with no signal for whether a
# skill is driving; separating them needs session-transcript inspection, which
# does not pay for itself against a few hundred bytes of prose.
{
  lib,
  pkgs,
}: let
  fragments = import ../../lib/fragments.nix {inherit lib;};
  swsContent = pkgs.stacked-workflows-content;
  # Single source for the description: it is both the composed fragment's and
  # the emitted instruction's, and it becomes the `description:` frontmatter
  # Kiro and Claude render. Names the RULE, not a routing table — the table it
  # used to describe is gone (see the header comment).
  description = "Requires checking stack-* skill coverage before hand-running git-branchless, git-absorb, or git-revise";
  composed = fragments.compose {
    # Named EXPLICITLY, not `attrValues passthru.fragments`. This composes an
    # ALWAYS-LOADED rule, so a blanket attrValues would silently enrol
    # any fragment later added to stacked-workflows-content into every session's
    # per-turn cost — re-inflating exactly what the header comment explains was
    # cut. Opting a new fragment in has to be a deliberate edit here, and the
    # bar for it is the one stated in lib/ai/mkSkillPackageModule.nix.
    fragments = [swsContent.passthru.fragments.skill-routing];
    inherit description;
  };
in {
  stacked-workflows-router = {
    inherit (composed) text;
    inherit description;
  };
}
