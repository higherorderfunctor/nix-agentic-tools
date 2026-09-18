# Gate 1 native observations

Observed 2026-09-12 through the filtered public toolchain and installed Scribe.
These findings qualify existing integration; they do not approve proposed
semantics. [native-observations.json](native-observations.json) contains the
disposable-root responses and runtime identity. [creation.json](creation.json)
records the actual public CLI commands that created the retained documents and
restored Base. [lifecycle.json](lifecycle.json) records the retained Base after
a native-devenv stop/start, exact-root readiness, check, info, and F1a show.

## Commands and results

```bash
bash tests/devenv.sh tasks run generate:sgra
bash tests/devenv.sh up -d scribe
bash tests/devenv.sh shell -- scribe-client --root "$PWD" ping
bash tests/devenv.sh shell -- scribe --root "$PWD" check
bash tests/devenv.sh shell -- strictdoc-grammar-extract tests/native_probe.py --output evidence/native-observations.json
bash tests/devenv.sh shell -- scribe-client --root "$PWD" reload
bash tests/devenv.sh down
bash tests/devenv.sh up -d scribe
# Repeat the bounded exact-root readiness, check, info, and show commands.
bash tests/devenv.sh down
```

Generation, native daemon startup and exact-root ping succeeded. The retained
Base has **10 nodes, 11 documents, and 0 native findings** after public reload.
The same counts and zero findings held after cold restart. Initial ping attempts
correctly refused while startup was pending; bounded retries returned the exact
fixture root. Final shutdown succeeded, and a subsequent ping refused because no
daemon remained. The native probe completed its smoke assertions successfully.
Its temporary roots contain only fresh neutral fixtures and explicit
grammar/config copies; no library implementation symbols are imported.

| Probe                                         | Observed result                                                                                        | Limit                                                                               |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------- |
| Required FLAG help and input validation       | Native help exposes explicit `false`/`true`; invalid value refused                                     | This validates grammar choices, not open/closed meaning                             |
| New, set, relate, unrelate                    | Written results match authored documents and public show                                               | No whole-batch guarantee follows                                                    |
| BAR owner/direction                           | M's document retains Parent P and Child Q declarations                                                 | No custom endpoint/path check exists                                                |
| Dry-run, invalid FLAG, missing target         | No authored-byte changes; public show of the affected node agrees with before                          | Ordinary refusal coverage, not publication/crash failure injection                  |
| Reload and cold restart                       | Public show retains changed I0.FLAG, removed F1 H, and M's owned P/Q; bytes unchanged                  | Native state agreement only                                                         |
| Mixed H/R/Q cycle                             | Candidate accepted and persisted; check reports `3 nodes, 0 finding(s)`; reload succeeds               | Violates the established global DAG requirement; Gate 1 exposes a real coverage gap |
| RPC array with one valid and one invalid edit | First result succeeds, second refuses; public show after reload reports I0 FLAG=true and I1 FLAG=false | Request arrays are not complete candidate transactions                              |
| Resolvable wrong FOO R target BAZ             | Accepted                                                                                               | G02 custom restriction unimplemented                                                |
| BAR Q behind closed F2                        | Accepted                                                                                               | T07 closed-boundary rule unimplemented; graph is independently acyclic              |
| BAR without endpoints                         | Accepted                                                                                               | B02 final cardinality unimplemented                                                 |

The mixed-cycle probe starts with B -> A through A-owned Parent H and A -> Z0
through BAZ-owned Parent R. Adding Z0-owned Child Q to B closes
`B -> A -> Z0 -> B`. No individual H/R/Q projection cycles, and no BAR
cardinality/path policy masks the global graph failure. This is G07's isolated
native counterexample, not a semantic traversal-negative pass.

The boundary and cardinality observations intentionally use raw public
operations rather than assertions requiring acceptance. If later work closes
those gaps, the observation script should report the changed responses; it must
not force an old missing rule to remain absent.

## Public interface discoveries

An explicit required string UID declaration is necessary. With no UID field in
the neutral grammar, `new` returned a written file but did not serialize the
supplied UID, and a subsequent mutation by that UID was refused as missing. The
corrected public grammar declares UID on every element, and native help then
exposes `--uid`. No prefix policy was added.

Installed Scribe requires AUTHORED_BY/PARENT_FP grammar declarations; new fills
AUTHORED_BY itself. These are accommodations, separate from proposed baseline
protection. The grammar uses string choices for FLAG because no public boolean
constructor is available.

The empty seed is a documented initialization exception. Before it existed, the
daemon started but `new FOO --help` refused because no document carried a
grammar. The seed imports `@repo`. Grammar discovery also needs root
`grammar.sgra` included by `strictdoc_config.py`; including only `documents/**`
caused resolution failure. The infrastructure worker corrected that
configuration, after which reload found the seed and generated FOO help.

Deleting the example M while its authored Child Q remained was refused as still
referenced by F2. The retained examples were snapshotted first, then normal
unrelate commands removed M's Q/P and F1a's R before deletion, restoring Base.
This is current native cleanup behavior; it does not settle ownership-sensitive
history or the proposed transaction boundary.

## Parent corpus separation

The replay started an independently owned installed `scribe-daemon` with
explicit root
`/home/caubut/Documents/projects/nix-agentic-tools-worktrees/strictdoc-module-restack`
and a temporary socket. Exact-root ping succeeded. Public info before and after
reload returned `dirty=false`, 496 documents and 496 nodes; generation advanced
from 1 to 2. Public show refused all 10 retained fixture UIDs as missing. The
daemon then stopped with exit code 0.

This measures exclusion with the fixture present, without reading or exporting
parent corpus contents. The fixture has its own root and 10-node Base, and its
positive snapshots are outside its default include path. Grammar, documents,
examples, contracts, creation evidence, and probe source retained their original
bytes throughout the replay.

## Remaining acceptance work

Whole native DAG enforcement and an actual candidate transaction are required
integration work. Custom semantics, external snapshot/provider behavior,
recovery after publication failure, lower semantic authoring layers, backend
choice, incremental/full semantic equivalence and scale remain pending later
gates. The 44-case contract gives their review inputs; this native probe does
not claim their completion. Equal BAR endpoints remain globally cyclic even if
the pending traversal convention allows a zero-length path.
