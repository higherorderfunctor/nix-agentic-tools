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

Run `devenv tasks run codeql:nix-db` from the repo's devenv shell. The task
snapshots `git archive HEAD` into `.devenv/state/codeql/nix/source` and skips a
matching commit and tool stamp. Dirty edits are absent. Rerun after committing
or pulling. The database and engine stay under `.devenv/state/codeql/nix/`.

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
