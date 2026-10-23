---
name: nix-codeql
description:
  Query this repo's committed Nix syntax, lexical scope and structural shapes
  with CodeQL. Use for relationships over .nix files; use direct reads for known
  paths and identifiers.
---

Use the existing codeql-nix AST and lexical scope library for structural
questions across this repo's `.nix` files. It does not evaluate Nix, resolve
imports or `with`, or parse embedded Bash. An unresolved expression is unknown;
read the source before calling it a defect.

Run `devenv tasks run codeql:nix:up` from the checkout to create or refresh a
stale database. `codeql:nix:refresh` forces replacement; `codeql:nix:down`
removes it. `codeql:status` prints generations, stamp ages, allocated sizes,
shared-base worktree references and totals; `codeql:gc` prunes unused shared
bases and orphan generations. Successful `up` and `refresh` also prune,
including when `up` reuses the database. State lives under
`<checkout>/.devenv/state/codeql/nix/`: `db` links to a complete generation,
`stamp` records its inputs on one line, and `engine` links the query engine.
Resolve `db` once per query request, and finish queries before replacing a
generation. CodeQL queries sharing a generation must serialize because they
share its writable result cache.

The pinned extractor lacks overlay support, so the database holds
`git archive HEAD`; dirty changes are absent. `up` checks the commit, merge-base
and tool paths. A shared warmed merge-base snapshot is copied with `cp -a` when
HEAD matches it. If a future extractor declares overlay support, each refresh
uses a fresh base copy plus the whole working diff, including untracked Nix
files. After a merge or branch checkout, an already active database refreshes in
the background; inspect `refresh.log` after a failure. Other changes need an
explicit `up`. No shell entry creates a database. Pruning retains the current
generation and unpublished generations younger than five minutes, and uses the
builder and shared-base locks. Shared bases survive only for exact current keys
from live worktrees' published stamps, plus the key just used. Missing
directories, missing or legacy stamps, unborn checkouts and unrelated histories
do not retain bases; interrupted `base.*` builds are removed under the shared
lock. A missing `origin/main` or another Git failure remains an error.
Generation publication fits intermediate query caches to 512 MB; source and
relations are outside that limit, and subsequent queries need
`--max-disk-cache=512` too.

Read [SCHEMA.md](SCHEMA.md) for the class and field summary. Import
`codeql.nix.Nix`, and prefix generated classes with `NIX::`; only common classes
have unprefixed aliases. Import `codeql.nix.Scope` for lexical binding
resolution.

Put an ad hoc pack in `.devenv/state/codeql/nix/queries/` with this `qlpack.yml`
(JSON also works):

```yaml
name: local/nix-queries
version: 0.0.0
dependencies:
  jamiemagee/nix-all: "*"
```

For example, save `Bindings.ql` beside it:

```ql
import codeql.nix.Nix
from NIX::Binding b
select b.getLocation().getFile().getRelativePath(),
  b.getLocation().getStartLine(), b.getAttrpath().toString()
```

Run `nix run .#codeql-query -- run nix <path-to-query.ql>`. The same command
accepts a database path in place of `nix`, or `-e '<QL text>'` in place of the
query file. It prints decoded JSON sorted by the first column; `--sort-key 0,1`
after `run` selects other columns. Sibling `.qll` imports and the query's
manifest are kept. Inline queries select the database language's visible `*-all`
library automatically.

The command uses the optional `ai.codeql.queryDaemon.enable` service when it is
running and falls back to `codeql query run` when its socket is absent. The
daemon keeps one warm evaluator per database, releases idle evaluators after
five minutes, and follows a replaced live `db` symlink on each request. It does
not rebuild or refresh databases. Use the lifecycle task before querying edits.
The configured engine supplies the extractor and `jamiemagee/nix-all`; no pack
download is needed. The shipped classification query is
`packages/codeql/ql/nix/StrictHeader.ql`; it reports `ok`, `missing` and
`unknown`, and is fixture-tested rather than a repo-wide gate.

A failed run prints the compiler's log and exits nonzero. Read the first `ERROR`
and its query line: an unresolved class often needs `NIX::`, an unbound variable
needs a finite binding, and a recursion error needs a positive recursive
relation before negation. Fix that query and rerun; do not treat a compile
failure or zero rows as evidence of absence. Prefer small AST and scope
predicates over introducing a new data-flow configuration.
