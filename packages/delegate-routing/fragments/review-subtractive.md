Append these rows to the rubric file, continuing its numbering, for the worker
and every reviewer. Grade a proposed fix against the same rows:

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
- **Necessity.** A missing test is a finding only once the code is shown needed:
  a caller or real input in the repository reaches it. Otherwise the finding is
  to delete the code.
- **One source of truth.** Each behavior is implemented once, and callers use it
  rather than wrapping it.
- **Readable in one pass.** A reader can state what the code does in two
  sentences without opening another file.
- **Abstract on the third repeat.** Repetition is a defect only when it
  duplicates a decision. If removing it would force a reader to jump between
  files to follow one idea, it stays.
- **Data over control flow.** Prefer one function driven by a table of cases
  over a chain of special cases. A case-specific branch needs a stated reason.
