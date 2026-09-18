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

One test exports the real corpus and needs `strictdoc`, which only the fixture
shell provides. When `strictdoc` is absent the runner enters that shell and runs
itself again there, saying so on standard error, so the plain command above runs
the whole suite. Set `FIXTURE_SHELL_ENTERED=1` to stay out of the shell; that
test then skips and names the command that provides it.

## Export the corpus

The corpus under `documents/` is the candidate's source. `export-candidate.sh`
runs StrictDoc's own JSON export over it and maps the result onto the contract's
record shape, so no `.sdoc` reader is reimplemented here. Run it inside the
fixture shell, which is where `strictdoc` lives:

```
cd <fixture root>
devenv shell -- contract/gate2/dsl-review/backend/export-candidate.sh \
  --out candidate.json
```

The result equals the delivered `../candidate.json` as a decoded object, which
is the contract's own comparison (contract.md:633-634). `tests/test_export.py`
asserts that equality, so the mapping cannot drift away from the corpus.
`--out -` writes to standard output instead, because StrictDoc's progress output
goes to standard error. `--created UID ...` fills the `created` list, which is
otherwise empty: newness is batch information the caller supplies
(contract.md:500-502) and an exporter of a settled corpus has none.

StrictDoc reads its input path as the PROJECT ROOT and resolves the `@repo`
grammar import from that root's `strictdoc_config.py`, so handing StrictDoc
`documents` aborts with `KeyError: '@repo'` — a path problem that reads like a
format problem. `--project` therefore takes the project root or any directory
inside it, and StrictDoc is given the nearest ancestor holding a StrictDoc
config; a walk up is reported on standard error, and a directory with no such
ancestor is refused with exit status 2. `--project <fixture root>/documents`
exports the same corpus as the root, because `include_doc_paths` already narrows
the export to `documents/**` and `grammar.sgra`; `tests/test_export.py` pins
both paths against the delivered candidate. The export is written into a
temporary directory that is removed on exit, so no run leaves a file under the
fixture tree.

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
- `sdoc_semantics/export.py`: maps a StrictDoc JSON export onto a candidate;
  imports nothing else in the package.
- `sdoc_semantics/__main__.py`: the command line front end; no evaluation logic.
- `export-candidate.sh`: runs the StrictDoc export and the mapping together.
- `tests/test_bundle_variants.py`: hand-built bundles for what the corpus cannot
  reach, such as a refused configuration or a blocked leaf.
- `tests/test_documentation.py`: the packet's prose against the sources it
  quotes.
- `tests/test_export.py`: the mapping rules one by one, plus the corpus export
  against the delivered candidate.
- `tests/test_fixtures.py`: discovers fixtures, compares produced against
  recorded.
- `tests/test_lowering_guards.py`: lowers each model under
  `fixtures/lowering-guards` and reads its refusal or its acceptance.
- `tests/test_variant_bundle.py`: each family's `bundle.json` against the
  lowering of its `model.nix`.
- `run-fixtures.sh`: runs the suite with the strict-mode header, from any cwd,
  entering the fixture shell when `strictdoc` is absent.

## Conformance rule

A fixture passes when its produced envelope agrees with its recorded one on
every normative field — `evaluation`, `baseline`, `status`, `findings`, and each
entry's `rule`, `status`, `causes`, `findings`. `message` is free text and is
never compared.

## Current suite result

60 passed, 60 total, nothing skipped, from `./run-fixtures.sh` at the fixture
root. Run that command to check whether this number is still current; a skip in
the tally means `strictdoc` was out of reach, not that a test is absent.

Purge `__pycache__` before reading a result you are about to act on, and after
any run that edited a module and put it back. Python invalidates bytecode by
source mtime in whole seconds and source size, so restoring a file of the same
size in the same second as the compile that preceded it leaves the EDITED
bytecode in place and every later run evaluates it. That is how a passing test
was measured against code that was no longer on disk during this review.

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
- Structural node types (`DOCUMENT`, `SECTION`, `TEXT`) carry no record and are
  skipped, while a node type the bundle does not declare is an error: emitting
  it would make the candidate an input error (contract.md:502-503) and dropping
  it would shrink the corpus silently.
- A field the bundle does not declare is dropped when the native grammar
  declares it, such as `AUTHORED_BY`, and is an error when neither declares it.
- A field authored in StrictDoc's block form carries the newlines that form
  encloses. The corpus writes `AUTHORED_BY:` followed by `>>>`, the word on its
  own line, and `<<<`; StrictDoc reports that value with its trailing newline,
  and the mapping passes it through, because the contract asks for the string
  exactly as authored. field-value compares native strings exactly, so a leaf
  naming the word alone matches no such record. Trimming here would instead make
  the exporter disagree with StrictDoc's parse and break preserve's byte
  comparison. Every `AUTHORED_BY` in the corpus is written this way, which is
  why the bundle leaves that field out.
- A File relation DECLARATION in the bundle grammar is dropped, for the same
  reason a File occurrence is: it names a path, so it declares no owned
  occurrence and carries no role. Rejecting the declaration while dropping the
  occurrence would refuse a grammar any `.sgra` can express.
- The exporter's `created` list is empty unless the caller names uids, because
  an exporter of a settled corpus has no batch.
