## CodeQL engines

> **Last verified:** 2026-10-22 — eleven engines at 2.27.3 from one `mkEngine`
> factory, the local query client with atomic inline packs and optional
> per-database daemon that interrupts socket reads on shutdown, plus the MIT Nix
> extractor at 0.3.0; the javascript engine wraps its launcher with a Node; CI
> builds javascript and evaluates the rest; the update input lanes build none.
> Packs and `customizePackage`: customize.md.

### What a bundle is

GitHub ships the CodeQL CLI as three things in one directory, `codeql/`:

- the **engine**: the `codeql` launcher, the evaluator's jars and a bundled JRE
  (`tools/linux64/java/`), plus `.codeqlmanifest.json`, which tells the launcher
  where extractors and packs live;
- one **extractor** directory per language (`javascript/`, `cpp/`, ...), each
  with its `codeql-extractor.yml`;
- **query packs** under `qlpacks/`: the standard libraries and queries.

A per-language bundle carries that language's extractor and packs plus those it
depends on (the actions bundle also carries javascript). The full bundle carries
every language. The bare CLI zip carries every extractor and no packs.

### The eleven engines

`ai.devTools.codeql.codeql-<engine>`, flat name `codeql-<engine>`:

| engine       | asset                                  | repository                   |
| ------------ | -------------------------------------- | ---------------------------- |
| `bare`       | `codeql-linux64.zip`                   | `github/codeql-cli-binaries` |
| `full`       | `codeql-bundle-linux64.tar.zst`        | `github/codeql-action`       |
| one language | `codeql-bundle-<lang>-linux64.tar.zst` | `github/codeql-action`       |

The languages are actions, cpp, csharp, go, java, javascript, python, ruby and
rust. All are x86_64-linux only (each recipe directory has a `platforms.nix`, so
the attribute is absent on Darwin). Each installs to `$out/share/codeql` with
`bin/codeql` symlinked to the launcher, which resolves its distribution by
following the symlink. The javascript engine's `bin/codeql` is instead a
`makeWrapper` of the launcher that sets `SEMMLE_TYPESCRIPT_NODE_RUNTIME` to its
`nodejs` argument (`passthru.nodejs`, swapped with
`.override { nodejs = ...; }`): the TypeScript extractor runs Node, and the
bundle ships none.

The leaf name repeats `codeql` because a flat package name is the last key of
its path (`lib/facets.nix` `flattenPackages`): `ai.devTools.codeql.javascript`
would publish a flat package called `javascript`. The `codeql` namespace keeps
the engines together under `ai.devTools`, and the prefix keeps every flat name
unique and matched by the `codeql` push filter.

`autoPatchelfIgnoreMissingDeps` lists the JREs' X11, font and sound libraries
and the .NET runtime's LTTng provider. The list was measured over every x86-64
ELF in the full bundle and the bare zip, which contain the same 123 objects;
everything else they need is glibc, libstdc++, libgcc_s, zlib or the bundle's
own libraries. It covers build-time linking only. What an extractor needs at run
time (a Python, a .NET ICU) is for the PR that wires that extractor.

### Licence position

Unfree under the GitHub CodeQL Terms, which forbid sharing, publishing or
distributing the CLI, and allow automated database creation only for an
OSI-licensed codebase hosted and maintained on GitHub.com.

So no engine may reach the public Cachix cache. Three guards, all aimed at
public publication:

- `pushFilter: kiro-cli|codeql` on every credentialed cachix-action step;
- `dev/scripts/ci-packages.py` excludes every `codeql-` name from the package
  shards, by prefix, so a new engine is excluded without an edit;
- the `test` job's tripwire asks the cache for every engine and every source
  asset and fails unless each answers 404
  (`dev/scripts/assert-not-published.sh`).

The private Hestia check cache in this repository's GitHub Actions cache MAY
hold an engine: a check builds one, and that is CI-internal storage, not
distribution. Only public publication is forbidden. The public `packages` output
omits the engines because they are unfree.

### Updates

One update target, `codeql-full`. Every engine carries the same
`passthru.updateScript`, a `mkUpdateScript` whose `platforms` are keyed by
engine, so one run moves the version and all eleven hashes together. The version
is the newest `codeql-bundle-v<x.y.z>` tag on `github/codeql-action`
(`git ls-remote`). `releases/latest` is wrong there: codeql-action's own `v4.x`
and `v3.x` releases interleave with the bundle tags.

### CI cost

CI builds ONE engine. `codeql-javascript-smoke` builds javascript and runs
`codeql version` (must equal the pinned version) and `codeql resolve languages`
(must list javascript). `codeql-engines-eval` evaluates every engine's drvPath
without building, and requires the flat `codeql-*` names to equal the
`sources.json` entries.

Building all eleven fetches 2.2 GB and unpacks and patches 5 GB, and none of it
is ever cached publicly, so every run would pay it again. Since the eleven
differ only in the asset, building one proves the shared body and evaluating all
proves every call site and pin.

The update pipeline's input lanes skip the engines for the same reason:
`verify_all_packages` builds every other `ciPackages` entry through
`ci-packages.py update-plan`, which drops the `codeql-` prefix from both the
expected set and the `--select`. An update PR still runs the smoke check in
`ci.yml`.

### External Nix extractor

`ai.devTools.codeql.codeql-extractor-nix` installs the prebuilt MIT v0.3.0
extractor through fetchurl and autoPatchelf, alongside the same tag's
`jamiemagee/nix-all` QL library. `extractor-sources.json` pins both assets; its
separate update target moves them together. No Rust build is involved. The
package's `codeqlLibraries.nix` names its library for `customizePackage`. All
existing public-cache guards stay in place; their `codeql` name filters
conservatively cover this package too. It carries no CLI.

`codeql-extractor-nix.codeql` exposes one javascript engine customized with this
extractor (`engine`), a `mkQueryPack` spec (`queries`), and `createDatabase`,
the script used by `codeql:nix-db`. A javascript bundle supplies CodeQL's util
and yaml packs, which the Nix library imports. `searchPath` discovers the
extractor; `additional-packs` cannot do that.

The explicit devenv task `codeql:nix-db` snapshots `git archive HEAD` under
`.devenv/state/codeql/nix/source` and creates `db` beside it. The stamp holds
HEAD and the engine and creator store paths, so dirty edits are excluded and
changes to the tools or snapshot mechanism rebuild it. An `engine` link supports
ad hoc queries through the dev-only `nix-codeql` skill. No task runs at shell
entry.

`codeql-nix-strict-header` compiles the shipped Nix query pack, resolves the
external language through merged and nested config files, checks conflicting
search paths are refused, and runs `StrictHeader.ql` over fixtures. It checks
`writeShellScript`, `writeShellScriptBin` and `writeShellApplication` for the
full strict header, including the application's `bashOptions` and the shopt in
`text`. Rows classify text as `ok`, `missing` or `unknown`; local lexical
bindings, concatenation and interpolation are followed, while an opaque helper
call remains unknown. This is a textual AST query, not Nix or Bash execution.
The whole repository is deliberately not a gate.

### Query client and optional daemon

`ai.devTools.codeql.codeql-query` ships
`codeql-query run <name-or-db-path> <query.ql>` and
`codeql-query run <name-or-db-path> -e '<QL text>'`. A name resolves from the
current checkout upward to `.devenv/state/codeql/<name>/db`; a path may name
that database or its containing state directory. Its adjacent
`engine/bin/codeql` selects the exact configured engine. Files keep their
sibling imports and manifest. Inline queries use a persistent content-addressed
pack whose dependencies are the database languages' visible `*-all` libraries;
ambiguous libraries require a query file in an explicit pack. Both the manifest
and query are published atomically so concurrent first-use clients see complete
files. Output is `bqrs decode --format=json --sort-key=0` JSON; `--sort-key`
accepts other comma-separated column indexes. Compilation failures print
CodeQL's diagnostic, including the query's path and line.

`ai.codeql.queryDaemon.enable = true` is the only daemon switch, off by default
and available on Home Manager and devenv. It declares
`ai.codeql.services.codeql-query`, lowered by `ai.services` to a user unit or
devenv process; normal service controls start and stop it. The socket is
`query.sock` under the service runtime directory,
`$XDG_RUNTIME_DIR/ai-service-codeql-query` or
`${TMPDIR:-/tmp}/ai-service-<uid>-codeql-query`, and is claimed through the
owner's path group. The daemon makes that directory private and locks it before
removing a stale socket. Clients use this socket automatically; an absent or
refused socket runs `codeql query run` and the same JSON decoder. Other socket
or query errors fail visibly. `--no-daemon` explicitly selects the fallback and
requires the database to be unlocked. Shutdown interrupts incomplete socket
reads before joining handlers, then releases evaluator sessions and removes the
socket; complete queries finish normally.

The daemon starts one `execute query-server2` lazily per resolved database and
engine, with a separate request lock per database. Different databases can run
concurrently. Aliases of the same target reuse one process.
`resolve ram --ram=6000 --format=json` supplies the server's heap and off-heap
flags; `--threads=4` bounds evaluation. A server releases its registration and
exits after 300 idle seconds. The daemon's `common-caches` persists under
`$XDG_STATE_HOME/codeql-query` (Home Manager) or `$DEVENV_STATE/codeql-query`
(devenv); the fallback's is under `$XDG_CACHE_HOME/codeql-query`. Each database
also keeps CodeQL's own writable evaluator cache.

Every request resolves the live `db` symlink again. A changed generation
detaches the previous registration and reuses or registers the new target; a
once-per-second idle sweep also releases generations whose links changed without
another request. An in-flight query finishes against the generation it resolved.
Plain database directories remain supported, but must not be mutated while
registered. Database creation, frontier warming, copying, refresh and generation
retirement belong to the lifecycle tool, which must retain old generations until
their users release them. The query daemon never changes source snapshots or
rebuilds a database.

`codeql-query` is the tiny-fixture integration check: fallback and socket JSON
agree; A/B/A requests preserve results and affinity; concurrent requests, inline
and edited queries, compile-error recovery, generation replacement, unlocked old
generations, idle exit and shutdown with incomplete clients are exercised
against the pinned engine. A lightweight transport regression pauses first-use
writes to each inline file while a second fallback caller compiles, and checks
SIGTERM with accepted idle and partial clients. The transport uses the 2.27.3
`vscode-codeql` `messages.ts` and `run-queries.ts` protocol:
`evaluation/registerDatabases`, `evaluation/deregisterDatabases` and
`evaluation/runQuery` with Content-Length framing. No initialization request is
required.
