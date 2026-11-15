# Source patches: least update friction

> **Last verified:** 2026-11-15 — operator rule from the Kimchi 1.15.1 bump;
> every patch goes through the shared `packageLib.patching` helper.

Pick the patch method that survives the most upstream churn while still failing
loudly when its target is gone. Best tool for the job, not one tool for all.

- **Patch decisions, not text.** Change the condition that makes the decision,
  as a one-line hunk (`if (true) return`, a function that `return true`s), and
  leave upstream's help text, messages and import blocks alone. An unused import
  or an unreachable message costs nothing; a hunk anchored on prose breaks on
  the next rewording. Accept stale upstream wording and document it.
- **A git patch by default, through the shared helper.** Use
  `packageLib.patching {inherit pkgs;}`: pass native `patches` to `attrs` for
  stdenv or to `source` for a patched tree, or `patchFiles` to `command` in
  shell. It applies with `-p1 --fuzz=0 --no-backup-if-mismatch`: no fuzz means
  the patch survives lines moving and refuses changed context, which is the loud
  failure we want, and no `.orig` backups land in the output. The Git caller may
  allow whitespace differences for pnpm patches GNU patch cannot read.
- **A pattern replace when the target is text that churns.** When a patch must
  remove or rewrite something that changes with the slightest rewording or
  reformat, a match-and-replace in the build (`substituteInPlace --replace-fail`
  for an exact anchor, or a regex replace over a loose pattern such as `.*`
  between two stable anchors) is allowed. It must fail when nothing matches:
  `--replace-fail`, or check the replace count and exit non-zero. A replace that
  silently matches nothing is a masking defect.
- **A byte patcher for binaries** stays exact and length-preserving. It refuses
  rather than guesses.

`patch-policy` catches direct patch calls and flag overrides; `patch-artifacts`
checks the patched source trees for `.orig` and `.rej` files.

When a patch breaks on a bump, that is ordinary maintenance. Fix the anchor, and
prefer moving it to a less brittle method over re-anchoring the same text.
