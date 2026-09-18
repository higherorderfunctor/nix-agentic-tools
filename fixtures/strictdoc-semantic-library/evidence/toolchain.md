# Clean toolchain delivery

<!-- cspell:ignoreRegExp /\b[0-9abcdfghijklmnpqrsvwxyz]{32}(?=-strictdoc-toolchain-source)/g -->

Verified 2026-09-12 against migrated repository source revision
`2d28787d3b5b4235b0a848b2ceb89c1eae4868ed` and the retained fixture. This report
covers delivery, not the proposed semantic rules.

## Refresh and native entrypoint

From this fixture directory:

```bash
bash bootstrap.sh
```

The script clears inherited `DEVENV_*`, `DIRENV_*`, and `SCRIBE_ROOT` variables,
builds the repository's `strictdoc-toolchain-source` package with
`--max-jobs 1`, replaces the ignored `.toolchain` directory, and runs
`devenv update library`. Re-run it after toolchain code or the repository
dependency lock changes. Restart a running fixture daemon after refreshing
implementation code.

The native configuration imports
`inputs.library.devenvModules.nix-agentic-tools`, selects
`inputs.library.packages.${pkgs.stdenv.hostPlatform.system}.strictdoc`, and
obtains the grammar DSL from `inputs.library.lib.ai.strictdocGrammar`. The
default installed source mode supplies the CLI, client, and daemon. The fixture
has no `flake.nix`.

Grammar declaration changes are a separate operation:
`devenv tasks run generate:sgra` renders `grammar.nix` to `grammar.sgra`; reload
or restart the daemon before relying on changed grammar. The consumer probes own
the lifecycle observations.

## Source boundary and pins

The built source is:

```text
/nix/store/121pk8i5nzhrpm34fv97f7mywin6k1r0-strictdoc-toolchain-source
```

Its 34 implementation files match the repository source byte for byte: 19
runtime files selected by the existing `scribeSource.nix` allowlist and 15
explicitly selected grammar/module files, including both the raw
`lib/grammar.nix` function and the native `lib/default.nix` export wrapper. The
only added files are a generated public `flake.nix` entrypoint and a generated
`flake.lock`: 36 files total. The expected set was derived from the explicit
runtime and Nix allowlists and compared with the actual output; grammar values
and document data were not reused.

The exported input contains no repository domain grammar values, semantic
engine, board assets, project corpus, fixture documents, or repository
configuration. The source exporter itself is also outside the exported consumer
source. This installs the existing public toolchain; it does not supply a
semantic backend.

The exporter derives the StrictDoc dependency subtree from the repository lock.
It traverses direct and follows dependencies and refuses follows that escape the
StrictDoc input. It does not maintain another copy of the upstream pins.

| Dependency           | Locked revision                            |
| -------------------- | ------------------------------------------ |
| Native devenv        | `190959a9a4bb52d4802f076a90c3c4e3aa2e6fa2` |
| Native shell nixpkgs | `c043004d1c6985732bcc1cbc5a9c9aecbbb4e0f0` |
| StrictDoc            | `7cf8183498ec87be531499230602df33523ed058` |
| StrictDoc's nixpkgs  | `f13ff45afd1bb73e640eaa08a7066dbed07e3238` |

The retained `devenv.lock` records the complete dependency graph. Offline
`nix flake metadata path:.toolchain` resolved the generated clean input with
`--no-write-lock-file`; the entrypoint and lock remained byte-identical to the
built output.

## Refresh controls

Source-refresh controls ran against an isolated copy of only the approved
implementation files, exporter, and repository lock. They did not edit the live
implementation.

| Control                                                                 | Observed result                                                                                                |
| ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Append a harmless comment to an allowed runtime source                  | New output `pvb4qg01d74d5m27swyi2g3f76vnv205-strictdoc-toolchain-source`; changed bytes present; 2.350 seconds |
| Add an unlisted file alongside the isolated sources                     | Same changed output; unlisted file absent; 1.279 seconds                                                       |
| Restore the original allowed source bytes                               | Exact original output `121pk8i5nzhrpm34fv97f7mywin6k1r0-strictdoc-toolchain-source`; 0.995 seconds             |
| Add a stale file and edit an allowed generated copy, then run bootstrap | Stale file removed and edited copy restored; all 34 source files matched again; 0.374 seconds                  |

The final bootstrap audit also confirmed that the input has exactly 36 files and
that the native library lock uses `.toolchain`.

A generated directory is intentional. The original delivery experiment found
that a Nix output symlink made devenv lock the resolved absolute store path. The
ignored directory retains the portable library path `.toolchain`; that path and
the entire fixture lock remained unchanged during this replay. The 34 generated
implementation copies are not tracked; their sources remain owned by the
toolchain.

The package is discovered from the native owner leaf
`packages/strictdoc-grammar/packages/strictdoc-toolchain-source/package.nix`.
Its public flat package name remains `strictdoc-toolchain-source`, and its
generated library wrapper preserves `lib.ai.strictdocGrammar`.

## Project separation

The parent project's document exclusion adds only
`fixtures/strictdoc-semantic-library/**`. The fixture itself binds alias `@repo`
to its generated grammar and includes `documents/**` and `grammar.sgra`, so the
parent exclusion does not remove the fixture's own data or grammar. Parent
corpus counts and fixture daemon behavior are verified separately through public
interfaces.

The replay confirmed native startup, exact-root readiness, check, reload, and
cold restart against the retained 10-node Base. The unchanged native probe
passed its smoke assertions. All fixture and disposable probe daemons were
stopped after measurement. Parent corpus counts and the absence of all 10
fixture UIDs were checked through a separately owned parent daemon, which was
also stopped; [native.md](native.md) records the results.

The fixture lock, grammar, documents, contracts, creation evidence, and probe
source remained byte-identical throughout replay. Formatting, shell syntax, and
`git diff --check` passed for the fixture delivery changes.
