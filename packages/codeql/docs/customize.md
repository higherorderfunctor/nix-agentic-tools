## CodeQL packs and customizePackage

> **Last verified:** 2026-10-21 (commit d088283e) — every engine carries
> `customizePackage`, `mkQueryPack` and `mkModelPack`; packs reach CodeQL
> through a generated `CODEQL_CONFIG_FILE`; query packs are precompiled; the
> wrapper passes signals on to a merged-config codeql.
>
> **Settled — do not relitigate.** Each was measured on the 2.27.3 javascript
> bundle and rejected:
>
> - **A symlink farm of the distribution with the packs inside it.** The
>   launcher accepts a farm, but the manifest globs do not descend a symlinked
>   directory (`codeql/javascript-queries` stopped resolving), a symlinked pack
>   root resolves zero queries, and a pack without a lock file in the
>   distribution root fails dependency resolution. A sibling of the distribution
>   is searched only one level deep and only in real directories.
> - **`--search-path` for the packs.** It survives a command-line
>   `--additional-packs`, but `--model-packs` finds extension packs only through
>   `--additional-packs`.
> - **`ai.devTools.codeql.mkQueryPack` through an owner `overlay.nix`.** The
>   overlay check (`lib/facets.nix` `changedLeafPaths`) compares every sibling
>   leaf of `ai` with `==`, which forces each derivation's outPath, so reading
>   any `pkgs.ai` attribute would instantiate every `ai` package.

### Surface

```nix
engine = ai.devTools.codeql.codeql-javascript;
engine.customizePackage { queries = [ ./ql ]; models = [ ./models ]; extraPackages = [ pkgs.gnumake ]; }
engine.mkQueryPack { name = "me/my-queries"; src = ./ql; }     # language defaults to the engine's
engine.mkModelPack { name = "me/my-models"; src = ./models; }
engine.override { nodejs = pkgs.nodejs-slim; }
```

The builders are passthru on each engine, because a query pack is compiled
against one engine. `language` defaults to a language bundle's own, must be
named on `codeql-full`, and must be a language the engine carries; `codeql-bare`
has no libraries and throws. `customizePackage` refuses a builder result whose
language the engine does not carry. Every field is optional, and a bad spec or
argument throws (`lib/customization.nix`, `lib/packs.nix`). `queries` and
`models` take a directory holding a qlpack.yml or a builder result.
`customizePackage` on a customized package appends. A store path given twice, in
one call or across calls, is used once; two paths holding one pack name throw,
because CodeQL calls a pack found in two locations an error.

The result has `bin/codeql`, a wrapper of the engine's, and `share/codeql`, a
link to the engine's. Nothing of the distribution is copied. Its `unwrapped` is
the engine, and it carries the engine's `mkQueryPack` and `mkModelPack`.

### How packs become visible

The wrapper sets `CODEQL_CONFIG_FILE` to a store file:

```text
--additional-packs <every pack>:<the aggregate model pack>
--model-packs nix-agentic-tools/customized-models
```

CodeQL reads that file in every subcommand, including the ones it starts itself.
Measured:

- The form is `--option value`. `--option=value` is ignored without an error.
- Each option keeps one value: a second line replaces the first, and the same
  option on the command line replaces the file's. A consumer who passes
  `--additional-packs` or `--model-packs` on the command line replaces these
  packs for that call.
- A model pack applies only when `--model-packs` names it, and a config line
  names one. So the wrapper builds one aggregate pack holding every model's data
  extensions, each under its index with its own `dataExtensions` globs, and
  `extensionTargets` merged. The copies drop their qlpack.yml, so each model
  pack resolves by its own name once.
- `CODEQL_CONFIG_FILE` replaces CodeQL's per-user `~/.config/codeql/config`. It
  does not add to it.

### A consumer's own config file is merged

The consumer's file is `CODEQL_CONFIG_FILE` when set, else
`~/.config/codeql/config`. If it exists, the wrapper writes the consumer's lines
and then its own to a `mktemp` file. It runs `codeql` as a child so it can
delete that file on exit, and passes HUP, INT and TERM sent to its own PID on to
that child.

A file that already holds every line of the wrapper's config is used as it is,
because it comes from a `codeql` this wrapper started, such as a build command
calling `codeql`.

A consumer file that sets `--additional-packs` or `--model-packs` exits 2 with a
message. The wrapper adds lines and does not join option values, and CodeQL
keeps one value per option, so the added lines would silently drop one side's
packs.

### Precompilation

`mkQueryPack` writes its qlpack.yml, with `codeql/<language>-all: "*"`, over
`src`, then runs `codeql pack create`. That needs no network: dependencies
resolve from the engine's bundled packs. The output is the pack with `.qlx`
plans, a lock file and the libraries it uses under `.codeql/libraries`, about 11
MB for javascript. In CI the two-query fixture compiled in 66 s and the
RequestForgery query in 98 s.

`mkModelPack` only writes its qlpack.yml (`extensionTargets`,
`dataExtensions: ["*.model.yml"]`). A directory given as it is stays uncompiled
and resolves the same way.

### The model check's kind

`codeql-model-pack-mutation` adds a `sinkModel` row
`["fakehttp", "Member[request].Argument[0]", "request-forgery"]`, and a second
pack the same row for `Member[fetchUrl]`. `RequestForgeryCustomizations.qll`
makes every `ModelOutput::sinkNode(_, "request-forgery")` a
`RequestForgery::Sink`, as the bundled `ext/axios.model.yml` does for axios. The
query selects `RequestForgery::Sink`. It finds nothing in the fixture without
the packs and exactly `request(...)` and `fetchUrl(...)` with them.

### Checks

`codeql-custom-query-pack` checks:

- the `.qlx` plans;
- resolution with no flag, while the plain engine does not resolve the pack;
- the merge with a consumer config file from `CODEQL_CONFIG_FILE` or `HOME`,
  with and without a final newline, where its `--search-path` pack still
  resolves; the refusal of a clashing one, and no refusal for a comment naming
  the option;
- the engine's Node in the extractor log;
- the four rows of a two-query pack (one query imports a `.qll`) over a `.js`
  and a `.ts` file.

`codeql-extra-packages` runs a program from `extraPackages` as
`database create --command`, which the plain engine cannot find. The program
runs the customized `codeql resolve packs`, with and without a consumer config,
and must list the pack. `codeql-model-pack-mutation` checks the rows above and a
`fetchUrl` row from a second model pack, adding each pack by customizing the
customized package, and the refusal of a consumer `--model-packs` line. All
three are x86_64-linux only. Their `$out` holds text.
