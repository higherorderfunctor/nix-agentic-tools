# Kiro v3 unfinished research corpus

This directory preserves unfinished Kiro v3 research for semantic retrieval. It
is intentionally an **ungroomed, non-authoritative snapshot**, not a plan to
finish the research.

Documents span multiple KAS releases, primarily 2.15.1 and 2.15.2. They mix
measured results, static source readings, inferred behavior, rejected claims,
open questions, and superseded intermediate conclusions. Internal paths and
cross-references preserve their original working locations and may no longer
resolve.

Everything below this README is preserved byte-for-byte as authored, with one
exception: `notes/kiro-primitive-fixtures-plan.md` was lightly edited on import
(private references removed, provenance header added) because its §6a defines
the F1-F8 phase-2 items the rest of the corpus cites. The directory is excluded
from repository formatting and markdown lints (see `treefmt.nix` and
`checks/split-code-spans.nix`): the ungroomed sources carry markdown defects
that reformatting "repairs" by mangling identifiers, and exact identifiers are
what semantic retrieval needs to hit.

When claims conflict, use this precedence:

1. Reproducible instruments and measured results under
   `dev/probes/kiro-workflows/`.
2. The working rules and contradiction ledger in
   `dev/references/kiro-workflows.md`.
3. Source-anchored research in this directory, accounting for its stated KAS
   version and evidence label.
4. Plans, prompts, and unverified hypotheses.

Do not silently combine contradictory claims. Record a working rule in the
reference ledger when a discrepancy affects implementation. Probe it only when
the answer would change a concrete design; unresolved rows are accepted research
debt, not an implied backlog.

## Preserved material

- `notes/` contains selected handoffs, source reads, documentation snapshots,
  and behavioral probe reports previously kept at the top of `private/`.
- `phase2/` contains the F09-F22 interface digests, ACP research, and their
  model-free probe inputs.

Generated aggregate output, orchestration transcripts, kickoff prompts,
prompt-construction documents, and mock-engine or harness-construction plans
were deliberately not imported. Those artifacts added duplication or described
an abandoned direction rather than Kiro's native workflow surface.
