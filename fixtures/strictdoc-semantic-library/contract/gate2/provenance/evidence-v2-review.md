All three actionable findings from [the prior review](evidence-v1-review.md) are
**resolved** within this bounded evidence review. No unresolved item remains
among those findings. The v2 cost/median disclosures are consistent, and
original results remain identified as v1.

**1. P2 — Selected Child normalization: resolved.**

[finalists.py](../research/experiments/scripts/finalists.py) now projects
selected Parent relations as target → owner and Child relations as owner →
target. Rustworkx and Cozo consume that projection; the NetworkX oracle
separately branches on authored kind and adds its own edges without calling
`selected_edges`. [policy.rego](../research/experiments/scripts/policy.rego)
implements the same two directions in `endpoints`, used by both adjacency maps.

The [literal Child input](../research/experiments/results/child-input.json)
selects Child/H and contains six Child edges, including F0 → F1 → F1a and F0 →
closed F2 → F2a/F2b. Its opposite-kind Parent shortcut is excluded. Ten
expectations are stated explicitly in `child_base`, independently of the
normalization helper: open descent true, reverse descent false, closed endpoint
true, blocked interior false, closed-origin descent true, internal peer/exit
true, external interior false, sibling descent false, and opposite-kind shortcut
false. These expectations are consistent with the authored fixture and
discriminate the original reversal.

[finalists.json](../research/experiments/results/finalists.json) records all
three backends matching all ten answers for `selected_child_base`. All three
also match the explicitly updated open-boundary expectations, where only
`blocked_interior` and `external_blocked` become true.
[opa-bun.cjs](../research/experiments/scripts/opa-bun.cjs) checks the literal
answers, opens F2, then closes it and checks the original answers again;
[opa-bun.json](../research/experiments/results/opa-bun.json) retains the ten
matching Child answers and passing controls. Counts reconcile to 30 graph
comparisons plus four capability records, versus v1's 24 plus four. The finalist
log's `comparisons: 34` counts all records; the correction and combined record
distinguish them correctly.

**2. P2 — Scratch-copy reproduction entry point: resolved.**

[reproduce.md](../research/reproduce.md) starts with
`packet="$PWD/inputs/research"`, creates disposable scratch, and copies
`experiments` before invoking setup or runner there.
[setup.sh](../research/experiments/scripts/setup.sh) and
[run.sh](../research/experiments/scripts/run.sh) derive experiment paths from
their own locations, directing probe dependencies/results to the copy.
`--backends` bypasses both native probes and host interop; it has no
filtered-toolchain dependency. Its finalist step regenerates both literal JSON
inputs before Wasm evaluation.

For `--all`, documentation matches the executable paths in the scripts: CLI
`/nix/store/qc5w0rnlr2pl8zvaaq5gi6jfhm7h50im-strictdoc/bin/strictdoc`, and
separate import environment
`/nix/store/cck3q51nd32dpbmpkwv5xpkxxhpnr2ak-strictdoc-env/bin/python3.14`. It
identifies StrictDoc revision `7cf8183498ec87be531499230602df33523ed058`, the
exact host toolchain-source artifact, and the existing effect-tui checkout/addon
at revision `d0d72543a79424242933ecfd557c4d5cbb27351d`. Missing artifacts
require separate acquisition and explicit scratch-path adjustment. The original
relative toolchain lookup is labeled producer-specific. Setup prerequisites and
its unexecuted reconstructed status remain explicit; neither runner mode hides a
build.

[combined-v2.json](../research/experiments/results/combined-v2.json) records the
producer's composed `--all` execution with exit 0 and existing dependencies,
without setup/network/builds. Its runner SHA-256 matches the retained script.
The [combined log](../research/experiments/logs/combined-v2.log) ends with the
matching completion message; individual command output is redirected by the
runner. Fail-fast sequencing places that message after all stages. This supports
the recorded host composition, not a personal rerun or new-host installation
qualification.

**3. P3 — Same nonempty snapshot protection: resolved.**

Both CLI and Wasm harnesses retain snapshot `protected-1` with
`I0: {closed: false}`. They first supply the identical projection and require
`[]`, then change only the projected field to true and require `["I0"]`,
checking snapshot identity. The CLI `external_snapshot_change` result and Wasm
`sameSnapshotProtection` result retain those two outputs. Rego compares each old
record with the candidate projection. A policy rejecting every protected key
would fail the unchanged control. CLI later-snapshot replacement assertions
remain present. This resolves the narrow comparison finding without expanding
its semantic scope.

**Measurement and version disclosure: consistent.**

The [correction](../research/evidence-corrections-v2.md), research cost table,
and handoff cost paragraph use v2 values. All nine completed medians in
[cost.json](../research/experiments/results/cost.json) recompute exactly from
three samples and round to the research table. The same three cells retain
eight-second process-budget exhaustion: Cozo deep at both sizes and OPA
10,000-wide. OPA 1,000-wide changed from 268.4934 ms to 1425.9833 ms, explicitly
disclosed as about 268 → 1,426 ms. The workload/process distinction from warm
Wasm remains explicit.

Wasm's twenty retained samples yield the conventional even-sample median
`(sorted[9] + sorted[10]) / 2 = 0.2412045 ms`; load is 2.529705 ms, consistent
with 0.24/2.53 ms in the text. The correction explicitly identifies v1's
unsampled upper-middle statistic. Original finalist, cost and Wasm results
remain under `*-v1.json`. Wasm's v1 bytes match the original hash directly;
finalist/cost v1 files have formatting differences, but two-space JSON
reserialization plus a final newline reproduces both original hashes. Their
retained data therefore reconcile with the original hash record; byte-for-byte
identity of those formatted copies is not claimed here.

Review actions were retained-file inspection, Python AST parsing of six scripts,
individual `bash -n` checks of three scripts, `node --check` of the Wasm
harness, JSON/result comparisons, hash checks, and median arithmetic. No
experiment, replay, build, installation, network access, delegate, Git
operation, production edit, interface proposal, or broad survey was performed.
Only outputs were written. The requested treefmt configuration was applied to
these two deliverables.
