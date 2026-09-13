# StrictDoc semantic-library fixture

**Gate 1 review draft.** This is a small retained native-devenv consumer and a
proposed behavior contract. Semantic rules are unimplemented, their outcomes
await review, and no backend has been selected.

From this directory, refresh the public toolchain and generate the grammar:

```bash
bash bootstrap.sh
bash tests/devenv.sh tasks run generate:sgra
bash tests/devenv.sh up -d scribe
bash tests/devenv.sh shell -- scribe-client --root "$PWD" ping
bash tests/devenv.sh shell -- scribe --root "$PWD" check
```

Detached startup returns before readiness; if ping is early, retry within a
bounded startup window. To inspect FOO or the loaded workspace:

```bash
bash tests/devenv.sh shell -- scribe --root "$PWD" show F0
bash tests/devenv.sh shell -- scribe-client --root "$PWD" info
```

Run public native smoke/probes in disposable roots using the module's installed
Python runner, then stop the retained fixture daemon:

```bash
bash tests/devenv.sh shell -- strictdoc-grammar-extract tests/native_probe.py
bash tests/devenv.sh down
```

`tests/devenv.sh` only clears inherited `DEVENV_*`, `DIRENV_*`, and
`SCRIBE_ROOT`, changes to this fixture root, and invokes normal devenv. It
prevents accidental reuse of a surrounding development shell's root. There is no
fixture flake, private store, or offline harness. Bash, Nix, and devenv are
bootstrap prerequisites; the native probe uses the delivered interpreter rather
than assuming a host Python installation.

## Review entry points

| Artifact                                       | Read it for                                                                  |
| ---------------------------------------------- | ---------------------------------------------------------------------------- |
| [contract/decisions.md](contract/decisions.md) | Pending choices and concrete visibility truth table                          |
| [contract/model.md](contract/model.md)         | FOO/BAR/BAZ vocabulary, direction, ownership and baseline proposal           |
| [contract/scenarios.md](contract/scenarios.md) | All 44 G/T/E/B/X cases and later-gate qualifications                         |
| [contract/surfaces.md](contract/surfaces.md)   | Existing grammar API and explicitly non-executable semantic surface sketches |
| [evidence/native.md](evidence/native.md)       | Measured native behavior, integration gaps and evidence limitations          |
| [evidence/toolchain.md](evidence/toolchain.md) | Filtered dependency identity and refresh/lock controls                       |

The review decision concerns the proposed contract. A native smoke result does
not approve those semantics or prove custom-rule enforcement. After behavior
approval, semantic expectation changes require a recorded user decision.

## Small native documents

`documents/` contains the base forest: F0/F1/F1a, closed F2 with F2a/F2b,
separate G0/G1, isolated I0, and BAZ Z0. It has 10 addressable nodes and 11
documents, counting the empty grammar seed. The base has no R edges and no BAR,
so each scenario can create a fresh M.

Every node was created through installed Scribe.
[documents/seed.sdoc](documents/seed.sdoc) is the sole manual bootstrap
exception: an empty document importing the generated grammar. An empty workspace
can start its daemon, but `new` needs at least one loaded document carrying that
grammar. The seed contains no semantic nodes.

Two readable Scribe-generated positive examples are retained outside the
configured document include path:

- [examples/bridge.sdoc](examples/bridge.sdoc) shows M owning Parent P=F0 and
  Child Q=F2.
- [examples/closed-endpoint.sdoc](examples/closed-endpoint.sdoc) shows F1a
  owning H=F1 and R=F2.

These snapshots are not loaded alongside Base. The F1a example has the same UID
as Base's F1a. To reproduce the proposed positive examples against Base, use
normal mutations rather than copying a duplicate document into `documents/`:

```bash
bash tests/devenv.sh up -d scribe
bash tests/devenv.sh shell -- scribe-client --root "$PWD" ping
```

Wait for a successful exact-root ping before running the mutations:

```bash
bash tests/devenv.sh shell -- scribe --root "$PWD" new BAR --uid M --path documents/M.sdoc --relate P=F0 --relate Q=F2
bash tests/devenv.sh shell -- scribe --root "$PWD" relate F1a --role R --target F2
```

For present-runtime cleanup, remove those authored relations before deleting M:

```bash
bash tests/devenv.sh shell -- scribe --root "$PWD" unrelate F1a --role R --target F2
bash tests/devenv.sh shell -- scribe --root "$PWD" unrelate M --role Q --target F2
bash tests/devenv.sh shell -- scribe --root "$PWD" unrelate M --role P --target F0
bash tests/devenv.sh shell -- scribe --root "$PWD" delete M
bash tests/devenv.sh down
```

These are separate native writes. They are not the proposed complete candidate
transaction, and incomplete BAR staging must not become an approved semantic
state merely because it is currently writable.

## Refresh and evidence

`bash bootstrap.sh` builds the parent's public `strictdoc-toolchain-source`,
replaces ignored `.toolchain`, and refreshes the native devenv lock. Rerun it
after toolchain code or root dependency-lock changes, then restart the daemon.
Grammar-only changes need `generate:sgra` and explicit reload/restart. The
generated `grammar.sgra` and `.toolchain` are artifacts; edit `grammar.nix`, not
their implementation contents.

To record a new observation run deliberately:

```bash
bash tests/devenv.sh shell -- strictdoc-grammar-extract tests/native_probe.py --output evidence/native-observations.json
```

The probe records installed runtime identity, grammar/lock hashes, real RPC
responses and observable resulting state. It asserts ordinary smoke properties
but records cycle/batch/missing-rule outcomes without requiring the current gaps
to persist. It does not implement a semantic evaluator, provider ABI, reference
traversal, or backend. Its temporary workspaces and foreground daemons are
cleaned up on normal completion or failure.

The filtered dependency shares the ordinary host/store while excluding unrelated
consumer context. Parent workspace corpus exclusion keeps nested fixture
SDoc/SGRA files out of parent loading. This is a lightweight consumer pattern,
not a hostile-agent sandbox.
