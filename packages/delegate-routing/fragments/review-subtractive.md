Add these rows to the rubric file for the worker and every reviewer:

- **Callers.** Each added line must name a caller or the concrete input it
  refuses (value, path or environment); otherwise remove it. A guard with a real
  but unstated refused input needs that input named where the guard lives. Flag
  wrappers, shims, compatibility branches and tests kept only to preserve an old
  shape; propose the simpler form when the code can collapse.
- **Same-change caller.** A caller counts only if it lands in the same change. A
  declaration, option, field or export whose first reader is in a later change
  moves there; one with no reader anywhere is deleted. The warning, check or
  mirroring the declaration itself drags in is not a reader.
- **Checks.** Each added check names the wrong implementation it fails on. A
  check whose expected value is built from the expression under test, or copies
  the implementation's string, fails on none: compare against a literal or an
  observed result, or delete it. A check for a race or a regression is shown to
  fail against the code before the fix.
- **Earliest layer.** For each refused input, ask which layer first sees it. If
  that layer can refuse it without dropping a supported case, refuse it there
  and delete the later guard. If nothing refuses it yet, add the refusal there
  rather than a guard downstream. Do not size a guard to an input that only a
  fallback or an over-broad argument lets through.
