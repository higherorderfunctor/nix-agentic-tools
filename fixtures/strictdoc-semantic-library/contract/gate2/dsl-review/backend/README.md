# Backend

A standard-library Python evaluator of the lowered contract. It reads a bundle
and a candidate, runs the rules, and writes a results envelope. No third-party
package, no pip, no network.

## Evaluate the sample

```
cd backend
python3 -m sdoc_semantics evaluate --bundle ../bundle.json \
  --candidate ../candidate.json --invocation ../invocation.json \
  --evaluation base-forest-expected
```

## Run every fixture

```
./run-fixtures.sh
```

## Package layout

- `sdoc_semantics/__init__.py`: package marker plus the public entry point.
- `sdoc_semantics/loading.py`: reads and indexes every config file; raises on a
  malformed one.
- `sdoc_semantics/model.py`: builds the record model and every preparation
  finding.
- `sdoc_semantics/graphs.py`: cycles, forest validity, ancestor and route
  primitives.
- `sdoc_semantics/findings.py`: builds every finding dict; compares every
  status.
- `sdoc_semantics/leaves.py`: the seven leaf kinds, dispatched by a table.
- `sdoc_semantics/visibility.py`: the shared visibility policy walk.
- `sdoc_semantics/select.py`: selector enumeration and the `where` filter.
- `sdoc_semantics/engine.py`: scheduling, expressions, `evaluate_bundle`.
- `sdoc_semantics/envelope.py`: envelope assembly and its ordering rules.
- `sdoc_semantics/providers.py`: external input acquisition; the only subprocess
  caller.
- `sdoc_semantics/__main__.py`: the command line front end; no evaluation logic.
- `tests/test_fixtures.py`: discovers fixtures, compares produced against
  recorded.
- `run-fixtures.sh`: runs the suite with the strict-mode header, from any cwd.

## Conformance rule

A fixture passes when its produced envelope agrees with its recorded one on
every normative field — `evaluation`, `baseline`, `status`, `findings`, and each
entry's `rule`, `status`, `causes`, `findings`. `message` is free text and is
never compared.

## Current suite result

21 passed, 21 total.

## Decisions where the contract was silent

- Envelope worst-of ranking is literal: a candidate that both violates one rule
  and blocks another can still read `blocked`.
- A leaf blocked by its own subject carries empty `causes`; its reason lives in
  the leaf's evidence, not a new cause kind.
- A cycle witness starts at the earliest vertex in candidate record order; one
  corpus fixture departs from this and is non-conformant.
- The graph-witness owner key is spelled `owner`, matching most of the corpus
  and avoiding a clash with finding-level `uid`.
- An invocation binding resolves per file by nearest ancestor, replacing rather
  than merging.
- Provider capture happens once per evaluation and is cached; a failed input
  reports `execution` before prerequisites are checked.
- With one input declaration, `baseline` is its identity or null on failed
  capture; two or more would be a configuration error.
- Prerequisite checks cover only existence and acyclicity; endpoint-count
  matching is treated as already enforced upstream.
- Preserve differences are ordered: existence, element, fields, then owned
  relations.
- Forest violations are ordered: cycles, then cardinality, then wrong-element
  endpoints.
- The `--evaluation` id is caller-chosen and echoed unchanged.
