# Split-inline-code-span lint — catches markdown where a `code span`
# straddles a newline.
#
# Rationale, the scanner's CommonMark rule, and why a naive regex is wrong
# all live in the module docstring of ./split-code-spans.py. Read that file
# before changing either half.
#
# Division of labour with treefmt:
#
#   - prettier (`settings.proseWrap = "always"` in treefmt.nix) is the
#     PRIMARY guardrail. It treats a code span as an unbreakable token, so
#     it joins any split span on format and can never emit one. Regressions
#     are caught by checks/formatting.nix, which already gates the tree.
#   - This check is the BACKSTOP for the residue prettier cannot reach:
#     CASCADING backtick mis-nesting, where one mis-paired span shifts every
#     backtick after it and prettier's own parse goes wrong (it DOES repair
#     an isolated one — see the docstring for the control that establishes
#     the distinction), plus any file excluded from prettier in treefmt.nix.
#
# The scan covers every `.md` in the source tree, minus treefmt's own
# markdown exclusions (`docs/plan.md`, sentinel-tip scratch that never
# merges, and `docs/plans/kiro-v3-research-raw/`, a verbatim research
# snapshot whose as-authored split spans are deliberately preserved —
# see the treefmt.nix comment for the mangling that joining them
# causes). Only git-tracked files reach the sandbox — see the "Flake
# Source Visibility" note in the nix-standards fragment — so a new file
# must be `git add`ed before this check can see it.
#
# `-type f` does not match symlinks, so tracked store symlinks (e.g.
# `dev/skills/repo-review/references/*.md`) go unscanned. That is deliberate
# and costs no coverage: their content is generated from sources this scan
# already reads. It is stated because a silent skip otherwise reads as
# coverage the check does not have.
{pkgs, ...}:
pkgs.runCommandLocal "split-code-spans-check" {
  src = ../.;
} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  cd "$src"

  # -print0/-0 so paths with spaces survive; -r so an empty tree is not an
  # invocation with zero arguments (the scanner would report success on a
  # file set it never received, which is the failure mode that makes an
  # empty scan indistinguishable from a passing one).
  ${pkgs.findutils}/bin/find . -type f -name '*.md' \
    ! -path './docs/plan.md' \
    ! -path './docs/plans/kiro-v3-research-raw/*' \
    -print0 \
    | ${pkgs.findutils}/bin/xargs -0 -r ${pkgs.python3}/bin/python3 ${./split-code-spans.py}

  ${pkgs.coreutils}/bin/mkdir -p "$out"
  ${pkgs.coreutils}/bin/touch "$out/ok"
''
