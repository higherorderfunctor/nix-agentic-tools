# Source patches: least update friction

> **Last verified:** 2026-10-15 — operator rule, after the Kimchi 1.15.1 bump
> broke two patches on help text and an import block.

Pick the patch method that survives the most upstream churn while still failing
loudly when its target is gone. Best tool for the job, not one tool for all.

- **Patch decisions, not text.** Change the condition that makes the decision,
  as a one-line hunk (`if (true) return`, a function that `return true`s), and
  leave upstream's help text, messages and import blocks alone. An unused import
  or an unreachable message costs nothing; a hunk anchored on prose breaks on
  the next rewording. Accept stale upstream wording and document it.
- **A git patch by default, applied with no fuzz.** Set
  `patchFlags = ["-p1" "--fuzz=0"]`: stdenv's default `-p1` lets GNU patch apply
  with fuzz 2, which can land a hunk in the wrong place silently. With no fuzz
  the patch survives lines moving and refuses changed context, which is the loud
  failure we want.
- **A pattern replace when the target is text that churns.** When a patch must
  remove or rewrite something that changes with the slightest rewording or
  reformat, a match-and-replace in the build (`substituteInPlace --replace-fail`
  for an exact anchor, or a regex replace over a loose pattern such as `.*`
  between two stable anchors) is allowed. It must fail when nothing matches:
  `--replace-fail`, or check the replace count and exit non-zero. A replace that
  silently matches nothing is a masking defect.
- **A byte patcher for binaries** stays exact and length-preserving. It refuses
  rather than guesses.

When a patch breaks on a bump, that is ordinary maintenance. Fix the anchor, and
prefer moving it to a less brittle method over re-anchoring the same text.
