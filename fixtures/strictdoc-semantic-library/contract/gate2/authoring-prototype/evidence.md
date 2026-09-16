# Bounded evidence

This isolated worker used Nix 2.34.4 and the supplied public native grammar
library. No builds, network requests, flake edits, production changes or Scribe
writes were performed. The copied input files are identified by
`producer-inputs.json`; the parent coordinator owns repository
revision/publication provenance.

From the isolated worker directory, the exact successful commands were:

```console
nix-instantiate --eval --strict --json outputs/prototype/evaluate.nix --arg grammarPath ./inputs/grammar-lib > outputs/prototype/evaluated.json
nix-instantiate --eval --strict --json outputs/prototype/controls.nix --arg grammarPath ./inputs/grammar-lib > outputs/prototype/control-results.json
python3 outputs/prototype/probe.py
```

Results: **57 Nix controls true**; **110 bounded runtime controls passed**.
`evaluate.nix` returns forced `normalized` JSON and native grammar rendering.
`controls.nix` asserts every control is true before returning. Runtime
assertions fail the process on any mismatch; `runtime-results.json` records
controls, synthetic Base input, per-case input deltas and structured results.
`rendered.sgra` is extracted from the successful actual native renderer output,
not hand-authored.

The publication layout changes `outputs/prototype/` to
`contract/gate2/authoring-prototype/`. Canonical examples remain beside that
directory. Its Nix entrypoints accept `libPath` and `grammarPath`; the default
grammar path points at the repository's public `packages/strictdoc-grammar/lib`.
The worker explicitly supplies its allowlisted copied library. The prototype
library imports only those public grammar constructors/check/render and public
nixpkgs lib. The grammar library itself is not a new implementation.

The final format invocation uses the supplied immutable formatter configuration:

```console
/nix/store/gxd8g3pfl781m59yfwvr176kjryzfx1m-treefmt-2.6.0/bin/treefmt --config-file /nix/store/9nv92dzkvnb3frsmfink5blwyg61444p-treefmt.toml --tree-root . outputs
```

Treefmt handles Nix, Markdown and JSON here; its supplied configuration has no
Python formatter. Python files still pass through treefmt as instructed, which
reports no Python formatter selection. Their execution is validated by the
probe.

## Evidence boundaries

- Native syntax checking/rendering is real existing-library evaluation. The
  rendered grammar is not claimed to have been parsed by StrictDoc or loaded
  through Scribe.
- Adjacent/external/direct target equivalence and independent schema/rule
  contribution conflicts are executed Nix controls. Generic module wiring and
  arbitrary custom-contract dependency validation remain future work.
- G01/G02/G03 structured target results come from two separate local algorithms.
  They are named shipped-style and independent to demonstrate entry parity;
  neither is an installed shipped implementation. Producer IDs differ
  intentionally; contextual findings, causes and decisions agree.
- Count zero/two cases and record-level endpoint paths execute. B01/B02 names
  refer only to final snapshots; ordered mutation/default/publication semantics
  are not executed.
- Paths use a supplied valid forest. Forest validation, all-role DAG validation,
  preservation, field endpoint resolution and virtual union-DAG behavior remain
  declaration/contract examples.
- Boolean encode/decode, invalid missing/multiple/unknown values including
  TBD/TBC, and typed literal/script option shapes execute. No runtime default
  provider executes.
- No registration/process transport, Scribe integration, defaults lifecycle,
  cache behavior, atomic mutation or publication/recovery guarantee is inferred
  from these probes.

## Independent-review corrections

The original 43 Nix and 51 Python controls still pass. Added controls cover
nested compound view/validity dependencies, the required native DAG meaning
guard, malformed RuleResult/Finding fields, qualified references, duplicate
identities, missing owners, cross-grammar selectors and preserving findings
before later input errors. Deadnix 1.3.2 also passes over `outputs` after the
supplied unused lambda fixes; schema callbacks continue accepting the complete
callback argument.

The supplied independent adversarial scripts were replayed unchanged through an
isolated `review-replay/work/canonical` symlink to the corrected `outputs`:

```console
nix-instantiate --eval --strict --json review-replay/work/adversarial.nix --arg libPath /nix/store/j2r11kxv91yl5xqppy3vy84klwxjbz1i-source/lib --arg grammarPath ./inputs/grammar-lib > review-replay/replay/adversarial-nix.json
python3 review-replay/work/adversarial.py
/nix/store/rfw9ylnssdaz8fnw1ld0zyzh24cih2hd-deadnix-1.3.2/bin/deadnix --fail outputs
```

Independent Python replay: **13 passed, 0 failed**, including the independent
162-case supplied-forest path oracle. Independent Nix replay now rejects both
compound-without-forest and required-native constant replacement, while
retaining the existing singleton controls.
[Review disposition](review-disposition.md) records the bounded fixes;
`review-regressions.json` records replay outcomes and the unchanged independent
control source digests. The canonical normalized/rendered reference artifact
remains unchanged after these corrections.
