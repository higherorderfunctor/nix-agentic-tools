## CodeQL packs and customizePackage

> **Last verified:** 2026-10-21 (commit 019ba0f0) — `ai.devTools.codeql` carries
> `mkQueryPack` and `mkModelPack`, which return pack specs; every engine's
> `customizePackage` realizes them; packs reach CodeQL through a generated
> `CODEQL_CONFIG_FILE`; query packs are precompiled; the wrapper execs codeql
> over a merged config named by its content, reused only when no other line sets
> its options.
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
> - **Engine passthru builders:** a stopgap for the overlay forcing #2810 fixed.
> - **A child codeql with a trap that deletes the merged config.** The 2.27.3
>   launcher runs java in the foreground and traps only EXIT, INT and TERM, so a
>   HUP left the JVM running on a deleted config, and the wrapper cannot reach
>   the JVM to forward signals; the wrapper execs over a file named by its
>   content instead (`git show 80d4c57a`).

### Surface

```nix
codeql = ai.devTools.codeql;
codeql.codeql-javascript.customizePackage {
  queries = [ (codeql.mkQueryPack { name = "me/my-queries"; src = ./ql; }) ./plain-dir ];
  models = [ (codeql.mkModelPack { name = "me/my-models"; src = ./models; }) ];
  extraPackages = [ pkgs.gnumake ];
}
codeql.codeql-javascript.override { nodejs = pkgs.nodejs-slim; }
```

`mkQueryPack` and `mkModelPack` return a pack spec, plain data
(`_type = "codeql-pack-spec"`, `kind`, `name`, `src`), and read no engine
(`lib/specs.nix`). The flake's `lib.ai.devTools.codeql` exports the same two
functions for a caller without the overlay.

A spec is not a derivation until an engine realizes it, because a query pack
compiles against one engine's bundled `codeql/<language>-all`: the same spec
realized by two engines is two packs. A builder that returned a derivation would
pick an engine before the consumer named one, so the namespace could not offer
it beside the eleven engines. `customizePackage` realizes each spec against the
engine it is called on (`lib/packs.nix`). A model pack's content is only its
language's, so two engines that carry it realize one derivation.

A language bundle supplies the language, and a spec's `language`, when given,
must be the bundle's. `codeql-full` needs `language` on the spec and throws
naming the field without it; `codeql-bare` has no libraries and throws. Every
field is optional, and a bad argument throws. `queries` and `models` take a
directory holding a qlpack.yml, a pack derivation or a spec of that field's
kind. `customizePackage` on a customized package appends. A store path given
twice, in one call or across calls, is used once, and two realized specs with
one pack name throw. A plain directory's pack name is not checked at eval time;
CodeQL reports a pack found in two locations when the packs are used.

The result has `bin/codeql`, a wrapper of the engine's, and `share/codeql`, a
link to the engine's. Nothing of the distribution is copied. Its `unwrapped` is
the engine, and its `packs` holds the realized `queries` and `models`.

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
`~/.config/codeql/config`; `/dev/null`, or a link to it, means none. If it
exists, the wrapper writes the consumer's lines and then its own to
`codeql-config-<uid>-<sha256>` under `XDG_RUNTIME_DIR` when it is a writable
directory, else `TMPDIR`, else `/tmp`, and execs `codeql`. The name comes from
the content, so the file outlives the wrapper and a `codeql` that codeql starts
reads it too. Each run writes it again and renames it into place over any file
of that name.

A consumer file that sets `--additional-packs` or `--model-packs` exits 2 with a
message. The wrapper adds lines and does not join option values, and CodeQL
keeps one value per option, so the added lines would silently drop one side's
packs. The one file used as it is holds every line of the wrapper's config and
sets those options with no other line: the merged file that a `codeql` this
wrapper started reads, such as a build command's. Any other line setting either
option, beside those lines too, is refused.

### Precompilation

A query spec's realization writes its qlpack.yml, with
`codeql/<language>-all: "*"`, over `src`, then runs `codeql pack create`. That
needs no network: dependencies resolve from the engine's bundled packs. The
output is the pack with `.qlx` plans, a lock file and the libraries it uses
under `.codeql/libraries`, about 11 MB for javascript. In CI the two-query
fixture compiled in 66 s and the RequestForgery query in 98 s.

A model spec's realization only writes its qlpack.yml (`extensionTargets`,
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

`checks/codeql-customize.nix`; each check's comment lists its arms. All are
x86_64-linux only, and their `$out` holds text. `codeql-custom-query-pack`
covers the `.qlx` plans, resolution, the merge with a consumer config and its
refusals, and the engine's Node. `codeql-extra-packages` runs a program from
`extraPackages` as `database create --command`, which runs the customized codeql
again. `codeql-model-pack-mutation` checks the rows above, appending, and the
refusal of a consumer `--model-packs` line.

`codeql-pack-specs` builds no engine. At eval, a spec is no derivation, a query
spec realized by `codeql-javascript` and `codeql-full` is two derivations and a
model spec one, and `codeql-bare`, `codeql-full` without `language` and a spec
in the other kind's field throw. `tryEval` cannot read a message, so a probe
evaluates `lib/customization.nix` over a stand-in engine and greps each refusal.
