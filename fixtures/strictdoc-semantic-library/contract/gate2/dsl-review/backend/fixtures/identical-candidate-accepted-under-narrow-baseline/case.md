- Situation: candidate bytes identical to
  warm-cache-recomputes-on-metadata-policy-baseline-change.
- Change: none. No baseline.json ships here, so the packet's baseline-I0-open
  binding applies and F1 is unprotected.
- Expected baseline-preserved: satisfied, differences [], baseline
  baseline-I0-open. Every other rule satisfied; envelope satisfied.
- Why: "A candidate record absent from the baseline is unprotected by preserve."
  (contract.md:355)
- Why one snapshot: "Capture one identified immutable snapshot per evaluation
  and reuse it throughout" (contract.md:529).
- Mixed: same uncovered obligation as its pair; nothing observes a cache.
- provenance: A08
