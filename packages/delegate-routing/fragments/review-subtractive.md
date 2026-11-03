Append these rows to the rubric file, continuing its numbering, for the worker
and every reviewer:

- **Callers.** Each added line must name a caller or the concrete input it
  refuses (value, path or environment); otherwise remove it. A guard with a real
  but unstated refused input needs that input named where the guard lives. Flag
  wrappers, shims, compatibility branches and tests kept only to preserve an old
  shape; propose the simpler form when the code can collapse.
- **Same-change caller.** A caller counts if it already exists or lands in the
  same change. A declaration, option, field or export whose first reader is in a
  later change moves there; one with no reader anywhere is deleted. The warning,
  check or mirroring the declaration itself drags in is not a reader.
- **Checks.** Each added check names the wrong implementation it fails on. A
  check whose expected value is computed by the expression under test, or read
  back from the input the check itself supplied, fails on none: write the
  expected value by hand or take it from an observed result, or delete the
  check. A check for a race or a regression is shown to fail against the code
  before the fix.
- **Earliest layer.** For each refused input, ask which layer first sees it. If
  that layer can refuse it without dropping a supported case, refuse it there
  and delete the later guard. If nothing refuses it yet, add the refusal there
  rather than a guard downstream. Do not size a guard to an input that only a
  fallback or an over-broad argument lets through.
