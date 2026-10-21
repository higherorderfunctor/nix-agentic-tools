## Kimchi CodeQL database

> **Last verified:** 2026-10-21 (commit f8707ca8) — `passthru.codeql` carries
> `source`, `database`, `runQueries`, `createDatabase` and `engine`; the
> `kimchi-codeql-database` check runs the smoke pack; `codeql:kimchi-db` creates
> the same database locally. No fact reads it yet.

### Three layers

`packages/kimchi/lib/codeql.nix`, reached through
`self.ciPackages.<system>.kimchi.passthru.codeql`:

- **`source`**: the tree the database is created from. It moves with the Kimchi
  or pi pins and with the flake's nixpkgs (stdenv, bash, jq, coreutils, patch).
- **`database`**: one CodeQL database of `source`, under `$out/db`. It moves
  with `source`, the engine and nixpkgs, so a nixpkgs bump costs one database
  rebuild of about 85 s.
- **`runQueries { name; queries; models ? []; }`**: every query of a
  `mkQueryPack` result, run against a copy of `database` by the
  `customizePackage` engine, with optional `mkModelPack` results.
  `$out/<query>.json` is `codeql bqrs decode --format=json` of every result set
  of `<query>.ql`, its tuples sorted.

Editing a query rebuilds its pack and its results. The database stays cached.
Select strings, relative paths and numbers only: an entity or an absolute
location carries the build directory into the JSON.

Every derivation name contains `codeql`, so the credentialed cachix steps'
`pushFilter: kiro-cli|codeql` keeps all of them out of the public cache. The
database is input-addressed and not bit-reproducible (`codeql-database.yml`
records its creation time). The Hestia check cache serves it again for as long
as the pins, the engine and the flake's nixpkgs stay the same.

### The source root

```text
kimchi/src/                              Kimchi's TypeScript, no *.test.ts, no __mocks__
kimchi/{package.json,tsconfig.json}
kimchi/node_modules/@earendil-works/<pi package>/{package.json,dist/}
```

- **Kimchi's GitHub release source, not the build's patched tree.** This is the
  tree `extract.mjs` reads, so a CodeQL fact and an `extract.mjs` fact describe
  the same code. This repository's packaging patches (`command-shell.patch`,
  `package-identity.patch`, ...) are not in it.
- **pi's four packages sit under `kimchi/node_modules`**, where Kimchi's imports
  resolve them. Measured: 506 of Kimchi's 508 `@earendil-works/*` import
  declarations resolve to a pi module in the database.
- **Kimchi's own `node_modules` (its pnpm store) is not in it.** That is every
  third-party dependency. The pi bundle chunks already hold what pi bundles from
  its own dependencies.
- **Source maps are dropped.** The extractor does not read them, and they are
  13.5 MB of pi's dist.
- **The extractor skips `node_modules` by default.**
  `LGTM_INDEX_FILTERS=include:kimchi/node_modules/@earendil-works` brings pi
  back in: without it the database held none of pi's files. The value is a
  directory: an include ending in `/**` fails with `Illegal use of '**'`.

### Minified files

`pi-coding-agent/dist/bundle/chunks/` holds pi's own CLI bundle, minified. It
inlines pi's dependencies, such as the AWS SDK, Google auth, undici and ws, and
their environment reads. 48 of the 237 variables in the current environment fact
are named in those chunks and nowhere else in pi, in Kimchi's source or in its
patches. The extractor skips a file it judges minified: without
`CODEQL_EXTRACTOR_JAVASCRIPT_ALLOW_MINIFIED_FILES=true` it skipped 46 files, 42
of them chunks and the rest vendored `*.min.js`. On 2.27.3 the database, logs
included, is 113 MB without the flag and 216 MB with it.

### The patch step

Kimchi's `package.json` `pnpm.patchedDependencies` names its pi patches
(pi-coding-agent, pi-ai and pi-tui at 0.85.1). Each one is applied to the
carried tree with `patch -p1 --fuzz=0`, as pnpm applies them in the build. A
patch for a pi package that is not carried, or for another version, fails the
build: a database without the patch would silently describe code that Kimchi
does not run.

### The database is a directory

`query run` and `database run-queries` refuse a bundle
(`Database root ... is not a directory`), and a query writes its cache into the
database: a read-only one fails with `Error acquiring the IMB cache lock`. So
every consumer copies the database first. Measured locally on the 214 MB
database: copying the directory took 0.1 s, unzipping its 100 MB
`codeql database bundle` 1.3 s, and building that bundle 10 s. `$out/db` drops
the creation `log/`.

`createDatabase` (`kimchi-codeql-create-database <dir>`) is the single place
that creates it. It copies `source` to `<dir>/source` and creates `<dir>/db`.
The derivation and the devenv task both run it.

### Running a query without Nix

```bash
devenv tasks run codeql:kimchi-db        # once per pin
state=.devenv/state/codeql/kimchi
"$state/engine/bin/codeql" query run --database="$state/db" \
  --additional-packs=packages/kimchi/ql --output=/tmp/out.bqrs \
  packages/kimchi/ql/smoke/EnvReads.ql
"$state/engine/bin/codeql" bqrs decode --format=json /tmp/out.bqrs
```

The task is explicit: nothing runs it before or after another task. It links the
plain engine at `$state/engine` and builds `createDatabase` through the flake.
It rebuilds only when `packages/kimchi/sources.json` or
`packages/codeql/sources.json` changes version. Delete `$state/stamp` after
changing `source` itself. Result paths are relative to `$state/source`.

`packages/kimchi/ql/qlpack.yml` makes the whole directory one local pack, so a
`.ql` file anywhere under it resolves `import javascript`. A query file outside
any pack fails with `could not resolve module javascript`. The pack needs no
lock file, and running a query writes none. Each subdirectory is also one
`mkQueryPack` source, and `mkQueryPack` writes that subdirectory's own
qlpack.yml. A query that imports a `.qll` from a sibling directory resolves
locally but not through `mkQueryPack`.

Measured on this host under load (load average 8 to 15 on 16 cores), with the
smoke query:

- the first run with a cold compile cache took 35 s;
- running the same query again took 5 to 10 s;
- an edited query took 17 to 25 s, about 15 s to compile and 2 to 3 s to
  evaluate.

For comparison, the Nix path compiles the pack (66 s for PR 2's fixture in CI)
before it evaluates.

### CI measurements

From the `checks (owner-kimchi)` job of run 39667792203 (2026-10-21, a 4-core
x86_64-linux runner, engine substituted from the check cache):

- `database` took 85 s: 58 s of extraction with 4 threads and 23.5 s of TRAP
  import. It holds 133.8 MiB of relations, a 56.0 MiB string pool and a 6.0 MiB
  source archive.
- `runQueries` on the smoke pack took 9 s, of which evaluation was 5.7 s. It
  returned 362 rows.
- `mkQueryPack` compiled the smoke pack in 33 s, in parallel with `database`.
- The check cache's drain pushed the job's 11 built paths, the database among
  them, in 85.6 MiB. Run 39670617753 had the same database derivation and copied
  it from the check cache in under 2 s, without building it.

### Licence

The CodeQL Terms allow automated database creation only for an OSI-licensed
codebase hosted and maintained on GitHub.com. Kimchi is Apache-2.0 at
`github.com/getkimchi/kimchi`. pi is MIT at `github.com/earendil-works/pi`, and
the database reads its npm dist, which is built from that repository.
