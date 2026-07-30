# Mode-F workflow definitions, and a standalone validator

Runnable workflow definitions for the mode-F harness, plus the validator that
makes them trustworthy **before** the operator launches anything.

## The circularity this directory exists to break

The engine ships a `validate_workflow` tool that would answer every question
about a definition authoritatively. It is unreachable. Workflow tool
registration is all-or-nothing on a single resolved boolean
(`records/workflow-surface.md`, R-workflow-4), the only way to make that boolean
true is to pre-seed a persisted session's metadata and re-enter it
(R-workflow-2), and the shipped CLI never supplies the setting on a fresh
session (R-workflow-3). So the tool that would vet a definition only exists in a
session you can only create by already having a definition worth seeding.

`contract.jq` breaks that circle. It re-implements the definition contract from
the bundle read recorded in `records/workflow-surface.md`, so a definition can
be checked with nothing running.

**This is a model of the engine, not the engine.** Two things follow, and both
are load-bearing:

- It can be wrong in the engine's favour — accept something the engine rejects.
  The mitigation is that every rule is traceable to a quoted schema or function
  in the record rather than to inference, and that section 7 of the self-test
  re-derives the contract's constants from the installed bundle on every run.
- It is deliberately **stricter** than the engine in places, because the
  engine's leniency there is silent. Every diagnostic says which case it is (see
  [Whose rule is it](#whose-rule-is-it)).

## Files

| File                        | What it is                                                                                                |
| --------------------------- | --------------------------------------------------------------------------------------------------------- |
| `contract.jq`               | the contract, as an executable `jq` filter emitting diagnostics                                           |
| `coverage.workflow.json`    | **generated, not runnable** — a validator fixture using all five node types                               |
| `drain-queue.workflow.json` | **generated** — the drain against ONE shared queue: K contending claimants                                |
| `drain.workflow.json`       | **generated** — the shard drain: `parallel` over K self-draining `repeat` branches                        |
| `generate.sh`               | emits all four definitions; **the only place K lives**                                                    |
| `self-test-negatives.json`  | the negative corpus, as data: one targeted mutation per rule                                              |
| `self-test-validate.sh`     | proves the definitions are clean, the generator is reproducible, and every rule rejects what it claims to |
| `smoke.workflow.json`       | **generated** — one step, no loop: proves an authored workflow ran at all                                 |
| `validate-workflow.sh`      | the driver: file handling, exit code, text and `--json` output                                            |

## Usage

```bash
./generate.sh                                   # regenerate the definitions
./validate-workflow.sh --strict ./*.workflow.json
./self-test-validate.sh                          # the thing to run before trusting any of it
```

`--strict` promotes warnings to failures. A definition meant to run unattended
should pass `--strict`; `coverage.workflow.json` deliberately does not, which is
what proves the warning channel reaches the exit code rather than being
decorative.

`--json` emits one JSON object per input file. Match on `code`, never on
`message` — the codes are the stable surface, and that is what
`self-test-validate.sh` consumes.

## Whose rule is it

Every diagnostic carries a `basis`, because it changes what an author should do:

| `basis`      | Meaning                                                                                                                         |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| `engine`     | the engine performs an equivalent check; the definition fails at load or throws at evaluation time whatever this validator says |
| `mechanical` | the file could not be read as a workflow at all                                                                                 |
| `policy`     | the engine **accepts** this. The rule exists because the acceptance is silent and the consequence is expensive                  |

All four documented authoring traps are `policy` — which is precisely why they
are traps. Nothing rejects them, so the only symptom is behavior: a loop that
never terminates, a stop condition that can never fire, a key that reads as
absent. The classification is not decoration: `contract.jq` carries it as a
table covering every code, and the self-test fails if any diagnostic is ever
reported without one, so a new rule cannot be added without saying whose it is.

## The four authoring traps

Full reasoning, with the quoted engine code for each, is in `contract.jq`'s
section headers. In brief:

1. **`jsonPath` is not JSONPath.** The engine does `split(".")` then repeated
   property access. `"$.drained"` reads a property literally named `$`, resolves
   to undefined, and the loop never stops.
2. **An array-valued `fileCheck.value` means "any of these candidates".** It
   does not mean "match this array" — the engine calls
   `value.some(c => deepEqual(resolved, c))`.
3. **`fileCheck.path` resolves against the workspace root**, never the process
   cwd, and throws if it escapes. A path still beginning with a template marker
   after substitution **skips containment validation entirely**, so a templated
   path is unchecked at author time and can only fail mid-loop.
4. **A `repeat` with neither `stopCondition` nor `stopWhen` is accepted.** The
   engine's only stop-form rule concerns defining **both**; there is no
   "requires one of" message anywhere in the validator. Such a loop runs to
   `maxIterations` with nothing reporting why it stopped. `stopWhen` also cannot
   express a file check at all — its dialect is exactly
   `{{expr}} contains <text>` and `<watchId>.terminal` — which is why the drain
   uses `stopCondition`.

## The drain

`parallel` over K independent self-draining `repeat` branches, one `step` per
branch, each branch owning exactly one shard state file and terminating on that
file alone. Two settings are counter-intuitive and `generate.sh` argues both at
length:

- **`joinPolicy: "allSettled"`, not `"all"`.** This corrects an earlier design.
  `"all"` aborts every sibling on the first branch **failure**, not only on
  completion, so one poisoned queue item would cancel every other branch. Under
  `"allSettled"` a failing branch is contained, the other K-1 drain to
  completion, and the run still reports `failed` — nothing is swallowed.
- **`onMaxIterations: "abort"`.** Not `"pause"`: resuming grants no further
  iterations and a paused run cannot be retried, so it is a state you cannot
  leave. Not `"continue"`: it marks the repeat COMPLETED on exhaustion, which is
  indistinguishable from a genuine drain, so an unfinished shard would score as
  success.

K is asserted into `1..20` because `maxStepNodes = 20` binds directly — each
branch spends one step node, and the count is structural, so K step nodes is the
whole budget.

### Run order for a live session

Run `smoke.workflow.json` first. It is one step with no loop and no concurrency,
so a failure there separates "the `workflowsEnabled` seed did not take" from "my
definition is wrong" — otherwise the same symptom, because a mis-placed seed
fails **silently**: `session/load` of an unknown id hydrates a fresh session
with the flag off and writes it over the path.

`bundled://ralph` is an even cheaper first probe since it needs no authored JSON
at all, but it is not a substitute: it contains no `parallel` node, so it
validates nothing about draining.

## What the self-test proves, and what it does not

Seven sections: the definitions validate as expected; the generator reproduces
them; K propagates to every derived quantity at both boundaries and is refused
outside them; every negative case is rejected **for its own reason**; the corpus
is complete and every rule is classified; the corpus is well-formed; the
contract's constants still match the installed bundle.

Two design points worth knowing before reading it:

- **Each negative is one mutation of a base the same run proved clean**, and the
  assertion is not "the mutant was rejected" but "the mutant reported the
  expected code **and** the clean base did not". A no-op `jq .` mutation is also
  run as a control, which is what rules out the mutation pipeline itself
  manufacturing the failures.
- **`UNVERIFIED` is not `ok`.** Section 7 keeps three outcomes apart: agreement,
  contradiction (real drift — stop), and a pattern it could not locate (usually
  a CLI upgrade moving the bundle's shape). The third is printed loudly and
  counted separately rather than passing quietly, and all seven unverified is a
  hard failure, because an extraction that has lost its grip is otherwise
  indistinguishable from a clean run.

**It does not prove the engine agrees.** Only a live run can do that, and the
live runs are operator-driven. What it proves is that these definitions satisfy
a contract transcribed from the engine, that the transcription still matches the
installed engine's constants, and that every rule in it demonstrably rejects
something.

## Notes

- **Nothing here starts a Kiro session or writes under `$HOME/.kiro`.** The only
  Kiro state read is the engine bundle, in section 7 of the self-test, via
  `harness/lib.sh`'s `kiro_resolve_bundle`.
- Sections 1-6 of the self-test use no `lib.sh` helper, and that is deliberate
  rather than an omission: every helper there locates live state, and a
  validator whose whole purpose is to run before anything is seeded has nothing
  to locate.
- `coverage.workflow.json` is a validator fixture and **must not be run**. It
  holds a `watch` node that would poll an external system.
- All shell here is bash, matching the rest of the corpus: `shopt` is not a zsh
  builtin, and the strict-mode constructs are bash-only.
