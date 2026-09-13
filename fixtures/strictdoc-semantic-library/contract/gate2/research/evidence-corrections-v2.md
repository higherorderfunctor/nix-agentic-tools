# Gate 2 evidence correction v2

Frozen on 2026-09-13 after the independent evidence audit. This is an explicit
correction to v1, not a claim that these controls ran in the original packet.
The coordinator retained the original frozen packet. `evidence-v1-sha256.json`
additionally records the producer's pre-correction publication-file hashes, and
`experiments/results/{finalists,cost,opa-bun}-v1.json` retain the original raw
result files. The backend recommendation and reviewed semantic requirements are
unchanged.

## Selected Child hierarchies

The audit correctly found that v1's shared `selected_edges` helper and Rego
adjacency always reversed owner/target. That was correct for selected Parent
relations only. V1's kind-selector control excluded a Child edge; it did not
select a Child-authored hierarchy. The separate native Child-ownership/cycle
probes were valid but did not establish traversal support in this direction.

V2 projects Parent as target -> owner and Child as owner -> target. The NetworkX
oracle now performs its own normalization instead of using the backend
projection helper. A literal Child-authored version of the hierarchy supplies
ten independently stated expectations: open descent, reverse-descent refusal,
reachable closed endpoint, blocked closed interior, closed-origin descent,
internal peer/exit, externally blocked interior, sibling-descent refusal, and
exclusion of an opposite-kind Parent shortcut. These are actual selected Child
edges, not only exclusion controls.

All three backends match those expected answers, then match explicitly updated
answers after the Child hierarchy's boundary opens. The same Rego compiled to
Wasm passes the ten Child expectations and boundary open/close controls under
Bun. V2 now records 30 evaluator comparisons and four additional capability
records, versus v1's 24 comparisons plus four records. Native Parent/Child/mixed
cycle and ownership controls remain in the combined replay.

Evidence: [literal Child input](experiments/results/child-input.json),
[finalist results](experiments/results/finalists.json),
[Wasm results](experiments/results/opa-bun.json), and the corrected
scripts/query artifact under `experiments/scripts`.

## Nonempty unchanged protection control

V1 tested changed protected content and empty snapshots. A policy that rejected
every protected key could have passed those assertions. V2 first supplies an
unchanged candidate projection under nonempty snapshot `protected-1` and
requires no violation, then changes only the projected field under that same
snapshot and requires `I0` to violate. Both CLI and Wasm results record the
passing and failing outputs. The original later-snapshot replacement controls
remain.

This corrects the discrimination of the narrow comparison probe. It does not
implement or qualify the deferred full ownership-sensitive baseline projection,
authenticated identity acquisition, or acquisition-to-verdict integration.

## Relocatable reproduction and composed replay

V1 reproduction commands assumed the producer's `outputs/experiments` and
`inputs/toolchain` layout. A frozen packet has neither writable producer outputs
nor an implied toolchain input. [Reproduction instructions](reproduce.md) now
begin by copying the packet's `experiments` directory to disposable scratch.
Both setup and runner write only relative to that copy.

`run.sh --backends` omits StrictDoc and the host addon. `run.sh --all` requires
the separately documented exact native CLI/Python store artifacts and existing
effect-tui checkout/addon. The original relative toolchain lookup is labeled
producer-specific; no toolchain/build acquisition is hidden in replay.

The composed `--all` runner was executed on the original host with existing
private dependencies and exited 0. This includes native probes, strict Rego
check, all finalist and external-provider controls, the expected bounded
Cozo-lock probe, Wasm build/evaluation, bounded cost probes and existing interop
controls. No setup, network acquisition or Nix build was run for v2.
[Execution record](experiments/results/combined-v2.json),
[runner log](experiments/logs/combined-v2.log). New-host setup/platform
qualification remains unclaimed.

## Rerun measurements and remaining boundaries

The research cost table and handoff now use the v2 combined-run measurements.
Original v1 measurements remain available separately. The generalized Rego
projection is slower on the completed 1,000-wide case (about 1,426 ms versus 268
ms in v1); this is a straightforward probe encoding, not an optimized backend
ceiling. It reinforces the existing performance caveat and does not change the
library-first/optional-OPA recommendation. The same three cost cells exceed the
eight-second worker budget.

The Wasm result now retains all twenty samples and computes the usual
even-sample median as the mean of the two middle sorted values. V1 retained only
an upper-middle statistic and no samples. V2's base-fixture median is about 0.24
ms, with 2.53 ms load; these remain a different workload/process boundary from
the larger CLI probes.

Still outside this evidence: production semantic composition/registration, full
ownership projections, Scribe candidate groups/publication recovery,
authenticated actor identity, full diagnostics, incremental/full qualification,
and supported-platform devenv closure. The correction does not reinterpret any
deferred work as implemented.
