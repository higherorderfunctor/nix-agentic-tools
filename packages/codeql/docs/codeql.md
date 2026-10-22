## CodeQL engines

> **Last verified:** 2026-10-21 (commit 044e6939) — eleven engines at 2.27.3
> from one `mkEngine` factory; the javascript engine wraps its launcher with a
> Node; CI builds javascript and evaluates the rest; the update input lanes
> build none. Packs and `customizePackage`: customize.md.

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
