# Stack skills scenario tests

Run against the current checkout with the flake's Git tools and Python on PATH:

```bash
bash packages/stacked-workflows/checks/scenario-tests/run.sh
```

For an immutable repository source tree without Git metadata:

```bash
bash packages/stacked-workflows/checks/scenario-tests/run.sh --source-dir /path/to/source
```

An optional positional revision reads fenced examples through `git show`; use
`--repo /path/to/checkout` to choose its repository. Current case IDs target the
current recipes, so historical revisions can fail extraction or assertions.
`--case ID` selects a case (repeatable). `--output /new/directory` selects a new
log directory; by default a unique directory is created under `TMPDIR`. No
existing output is deleted or reused.

The runner never invokes Nix or contacts a network service. Git pushes and
fetches use each case's local bare origin. It requires Bash, Python 3, Git,
git-absorb, git-branchless and git-revise on PATH. The Nix check supplies the
flake's packages and reads the immutable flake source:

```bash
nix build .#checks.x86_64-linux.stacked-workflows-scenarios -L
```

Cases run sequentially in sorted order, with fixed commit identities, dates and
fixture contents. Each owns its primary checkout, linked worktrees, `HOME`,
`XDG_CONFIG_HOME` and temporary directory. Inherited Git environment variables
are cleared and `GIT_CONFIG_NOSYSTEM=1` disables system config.

The 59 original cases retain their assertions; three additional cases cover
reference recipes 5, 13 and 16. Retired history-layout checks, old result files
and the inventory are not inputs. Every failed assertion or execution error
fails the check; there are no expected-failure exemptions.

## What is checked

Each manifest names ordered block IDs (`file::heading::ordinal`), roles,
topology, environment and expectations. Missing or unused IDs fail. A case also
fails when a block no longer contains the command it runs; after a deliberate
edit, update that case's `block_ids` and markers in `cases/`. Executed blocks
come from the selected source, with fixture substitutions recorded. Mutually
exclusive documented alternatives use only the applicable subsection. The
speculative hide case executes the cleanup line after preparing the graph; the
split case replaces interactive staging and editing with fixed inputs.

Before/after snapshots check other worktrees' HEAD, branch, index and status;
primary/main stability; unexpected branch deletion; upstream refs, reachable
commit trees and unintended upstream path changes. Newly recorded branchless
events may not rewrite or hide upstream-reachable commits. Case-specific
endpoints check the intended final content and topology.

Command tracing records failed or empty selections and rejects later mutation.
The trace file is sourced into the deliberately non-strict example shell: adding
strict mode would change the documented behavior being tested. It observes
failures without preventing an unsafe command from running.

`RESULTS.md` contains a failure table; `results.json` records every case.
Per-case directories retain command logs, exact executed shell blocks, ordered
IDs, individual assertions and before/after snapshots. Static cases prove only
their stated text predicate. Execution errors mean unverified coverage.
Hosting-service PR APIs are outside this check.
