## Kimchi CodeQL database

> **Last verified:** 2026-10-22 — dependency patches use
> `git apply --ignore-space-change`; the database carries pi-mcp-adapter's root
> TypeScript and dist, including its patched project-trust environment read.

### Three layers

`packages/kimchi/lib/codeql.nix`, reached through
`self.ciPackages.<system>.kimchi.passthru.codeql`:

- **`source`**, internal to the file: the tree `database` is created from, not a
  passthru attribute. It moves with the Kimchi or pi pins and with the flake's
  nixpkgs (stdenv, bash, jq, coreutils, git).
- **`database`**: one CodeQL database of `source`, under `$out/db`. It moves
  with `source`, the engine and nixpkgs, so a nixpkgs bump costs one database
  rebuild of about 85 s.
- **`runQueries { name; queries; models ? []; on ? database; }`**: every query
  of an `ai.devTools.codeql.mkQueryPack` spec, run against a copy of `on` with
  optional `mkModelPack` specs. `engine.customizePackage` realizes the specs,
  compiling against the engine that built the database. `databaseOf name tree`
  builds a database of another tree laid out as `source`. `$out/<query>.json` is
  `codeql bqrs decode --format=json` of every result set of `<query>.ql`, its
  tuples sorted. `mkQueryRunner { queries; models; }` is the same run as a
  script, `kimchi-codeql-run-queries <db> <out>`.

Select strings, relative paths and numbers only: an entity or an absolute
location carries the build directory into the JSON. Every derivation name
contains `codeql`, so the credentialed cachix steps'
`pushFilter: kiro-cli|codeql` keeps all of them out of the public cache. The
`Assert no CodeQL engine or database is published` tripwire in `ci.yml` also
asserts 404 there for both databases, the release's and the network fixture's,
and for every other CodeQL derivation the network check needs. The database is
input-addressed and not bit-reproducible (`codeql-database.yml` records its
creation time). The Hestia check cache serves it again for as long as the pins,
the engine and the flake's nixpkgs stay the same.

### The source root

```text
kimchi/src/                              Kimchi's TypeScript, no *.test.ts, no __mocks__
kimchi/{package.json,tsconfig.json}
kimchi/node_modules/@earendil-works/<pi package>/{package.json,dist/}
kimchi/node_modules/pi-mcp-adapter/{package.json,dist/,<root JS/TS modules>}
```

- **Kimchi's GitHub release source, not the build's patched tree.** This is the
  tree `extract.mjs` reads, so a CodeQL fact and an `extract.mjs` fact describe
  the same code. This repository's packaging patches (`command-shell.patch`,
  `package-identity.patch`, ...) are not in it, and neither is Kimchi's upstream
  postinstall rewrite: `scripts/patch-pi-ai-oauth.js` replaces pi-ai's
  `dist/utils/oauth-page.js`, and `extract.mjs` does not apply it.
- **pi's four packages sit under `kimchi/node_modules`**, where Kimchi's imports
  resolve them. Measured on 1.17.2: 506 of Kimchi's 508 `@earendil-works/*`
  import declarations resolve to a pi module in the database. The TypeScript
  extractor scanned only pi-coding-agent's dist, saw the other three as
  `index.d.ts` types and read patch `+` lines; the database holds all four
  `dist/` trees, patched. On 1.17.0 the environment fact is the same either way.
- **Kimchi's own `node_modules` (its pnpm store) is not in it.** That is every
  third-party dependency except pi-mcp-adapter and what pi's bundle inlines
  (below). The adapter exports root TypeScript modules, so its root JS/TS files
  are carried with its dist. Its docs, examples and skills are not code the
  runtime loads and are not copied.
- **Source maps are dropped:** 13.5 MB on pi 0.85.1 that the extractor never
  reads.
- **The extractor skips `node_modules` by default.**
  `LGTM_INDEX_FILTERS=include:kimchi/node_modules` brings pi back in: without it
  the database held none of pi's files. The value is a directory: an include
  ending in `/**` fails with `Illegal use of '**'`.

### Minified files

`pi-coding-agent/dist/bundle/` is pi's minified standalone CLI, which Kimchi
never loads. It is carried for the environment reads of pi's bundled third-party
dependencies (AWS SDK, Google auth, undici, ws) at pi's build-time versions: 48
of the 237 variables in the 1.17.2 environment fact are named in its chunks and
nowhere else in pi, Kimchi or its patches. It also holds unpatched copies of
patched pi-ai, pi-tui and pi-coding-agent code, so a query scopes or labels its
`dist/bundle` rows. The extractor skips a file it judges minified: without
`CODEQL_EXTRACTOR_JAVASCRIPT_ALLOW_MINIFIED_FILES=true` it skipped 46 files: 42
chunks, the three `dist/bundle` entry files (`cli.js`, `index.js`,
`rpc-entry.js`) and the vendored `marked.min.js`. The flag grows the 2.27.3
database, logs included, from 113 to 216 MB.

### The patch step

Kimchi's `package.json` `pnpm.patchedDependencies` names its dependency patches.
Each patch whose package is carried is applied to the carried tree with
`git apply --ignore-space-change`. Every context line must match, allowing
whitespace changes; pnpm compares lines after trimming trailing whitespace only.
GNU patch with zero fuzz rejects two shapes pnpm accepts in the pi 1.3.0
patches: pi-ai's missing final-newline marker and pi-coding-agent's unequal
leading/trailing context counts in a hunk that does not end at EOF. Git accepts
both and produces byte-identical files to pnpm for Kimchi 1.19.1. A patch for a
pi package that is not carried, or for another version, fails the build. Only
carried packages' patches are in the database; `source` refuses another whose
added lines name `env` (kimchi-codeql-environment.md).

### The database is a directory

`query run` and `database run-queries` refuse a bundle
(`Database root ... is not a directory`), and a query writes its cache into the
database: a read-only one fails with `Error acquiring the IMB cache lock`. So
every consumer copies the database first. Measured locally on the 214 MB
database: copying the directory took 0.1 s, unzipping its 100 MB
`codeql database bundle` 1.3 s, and building that bundle 10 s. `$out/db` drops
the creation `log/`. `createDatabase`
(`kimchi-codeql-create-database <dir> [<tree>]`) copies `<tree>`, by default
`source`, to `<dir>/source` and creates `<dir>/db`; the derivation, the devenv
task and the environment guard all run it.

### Running a query without Nix

```bash
devenv tasks run codeql:kimchi-db        # once per pin
state=.devenv/state/codeql/kimchi
"$state/engine/bin/codeql" query run --database="$state/db" \
  --additional-packs=packages/kimchi/ql --output=/tmp/out.bqrs \
  packages/kimchi/ql/smoke/EnvReads.ql
"$state/engine/bin/codeql" bqrs decode --format=json /tmp/out.bqrs
```

The task is explicit: nothing runs it before or after another task. It rebuilds
only when `packages/kimchi/sources.json` or `packages/codeql/sources.json`
changes version. Delete `$state/stamp` after changing
`packages/kimchi/lib/codeql.nix` (the source tree, the patch step or the
extractor environment) without a pin bump. Result paths are relative to
`$state/source`.

`packages/kimchi/ql/qlpack.yml` makes the whole directory one local pack, so a
`.ql` file anywhere under it resolves `import javascript`. A query file outside
any pack fails with `could not resolve module javascript`. Each subdirectory is
also one `mkQueryPack` source, which writes its own qlpack.yml, so a query
importing a sibling directory's `.qll` resolves locally but not through
`mkQueryPack`.

Measured with the smoke query on a 16-core x86_64-linux workstation: a cold
first run took 35 s, the same query again 5 to 10 s, an edited query 17 to 25 s
(about 15 s to compile). The Nix path compiles the pack first: 66 s in CI run
39642944093 for the codeql-customize checks' two-query pack.

### CI measurements

From the `checks (owner-kimchi)` job of run 39667792203 (2026-10-21, a 4-core
x86_64-linux runner, engine substituted from the check cache):

- `database` took 85 s (58 s of extraction with 4 threads, 23.5 s of TRAP
  import): 133.8 MiB of relations, a 56.0 MiB string pool, a 6.0 MiB archive.
- `runQueries` on the smoke pack took 9 s (5.7 s evaluation) for 362 rows.
- `mkQueryPack` compiled the smoke pack in 33 s, in parallel with `database`.
- The check cache's drain pushed the job's 11 built paths (85.6 MiB); run
  39670617753 copied the same database from it in under 2 s instead of building.

### Licence

The CodeQL Terms allow automated database creation only for an OSI-licensed
codebase hosted and maintained on GitHub.com. Kimchi is Apache-2.0 at
`github.com/getkimchi/kimchi`. pi is MIT at `github.com/earendil-works/pi`, and
the database reads its npm dist, which is built from that repository.
