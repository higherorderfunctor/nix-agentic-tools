## CodeQL packs and customizePackage

> **Last verified:** 2026-10-23 — specs defer realization to engines; query
> packs are precompiled; one wrapper merges `CODEQL_CONFIG_FILE`, with
> content-addressed reuse for child processes and validated custom languages.
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

Specs defer engine selection until `customizePackage` realizes them in
`lib/packs.nix`. A query compiles against that engine's `codeql/<language>-all`,
so two engines realize two query packs. A model pack is language-specific but
engine-independent: both realize one derivation.

A language bundle supplies the default language; explicit `language` may also
select a supplied library. `codeql-full` and `codeql-bare` need `language`;
without supplied libraries, bare rejects specs. Every field is optional, and a
bad argument throws. `queries` and `models` take a directory holding a
qlpack.yml, a pack derivation or a spec of that field's kind. `customizePackage`
on a customized package appends. A store path given twice, in one call or across
calls, is used once, and two realized specs with one pack name throw. A plain
directory's pack name is not checked at eval time; CodeQL reports a pack found
in two locations when the packs are used.

The result wraps `bin/codeql` and links `share/codeql` without copying the
distribution. `unwrapped` is the engine; `packs` holds realized `queries` and
`models`.

### Custom languages

The existing wrapper and `lib/packs.nix` accept optional `extractors` and
`libraries`, preserving bundled defaults. Records are
`extractors = [{ src = descriptorRoot; language = "fixture"; schema = "fixture.dbscheme"; }]`
and
`libraries = [{ src = qlpackRoot; language = "fixture"; name = "nix-agentic-tools/fixture-all"; schema = "fixture.dbscheme"; }]`.
Each language requires one extractor/library pair with the same schema basename.
Builds validate descriptor name, library name, `library: true`, `dbscheme`, and
byte-identical schema contents, including derivation-backed sources. Query
`language` selects that library name; model extension targets use it too.
Extractor roots and the original engine form `--search-path`; libraries join
`--additional-packs`. Records append and deduplicate across calls; conflicting
language claims and known pack names fail. Config merging and child reuse use
the existing wrapper, which also refuses foreign `--search-path` when owned.

### How packs become visible

The wrapper sets `CODEQL_CONFIG_FILE` to a store file:

```text
--additional-packs <every pack>:<the aggregate model pack>
--model-packs nix-agentic-tools/customized-models
```

Every subcommand, including children, reads that file. Measured:

- The form is `--option value`. `--option=value` is ignored without an error.
- Each option keeps one value: a second line replaces the first, and the same
  option on the command line replaces the file's. A consumer who passes
  `--additional-packs` or `--model-packs` on the command line replaces these
  packs for that call.
- Only the named `--model-packs` pack applies. The wrapper aggregates every
  model's extensions under its index, retaining its `dataExtensions` globs and
  merging `extensionTargets`. Copies omit qlpack.yml to avoid duplicate names.
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

A consumer line setting a wrapper-owned option exits 2 with a message: appending
would silently replace its value. Only a file containing every wrapper config
line, with no other line setting those options, is reused directly. This lets a
child codeql, such as a build command's, reuse the merged file.

### Precompilation

Query realization writes qlpack.yml with the selected dependency over `src`,
then runs `codeql pack create` offline using bundled or supplied libraries.
Supplied libraries are staged as writable copies: CodeQL preserves dependency
modes, then rewrites their manifests. Output holds `.qlx` plans, a lock and
libraries under `.codeql/libraries`.

Model specs only write qlpack.yml (`extensionTargets`,
`dataExtensions: ["*.model.yml"]`); plain directories stay uncompiled.

`codeql-model-pack-mutation` adds a `sinkModel` row
`["fakehttp", "Member[request].Argument[0]", "request-forgery"]`, and a second
pack the same row for `Member[fetchUrl]`. `RequestForgeryCustomizations.qll`
makes every `ModelOutput::sinkNode(_, "request-forgery")` a
`RequestForgery::Sink`, as the bundled `ext/axios.model.yml` does for axios.
Selecting `RequestForgery::Sink` finds nothing without the packs and exactly
`request(...)` and `fetchUrl(...)` with them.

### Checks

`checks/codeql-customize.nix` lists each check's arms; all are x86_64-linux,
with text outputs. `codeql-custom-query-pack` covers the `.qlx` plans,
resolution, the merge with a consumer config and its refusals, and the engine's
Node. `codeql-extra-packages` runs a program from `extraPackages` as
`database create --command`, which runs the customized codeql again.
`codeql-model-pack-mutation` checks the rows above, appending, and the refusal
of a consumer `--model-packs` line.

`codeql-pack-specs` builds no engine. At eval, a spec is no derivation, a query
spec realized by `codeql-javascript` and `codeql-full` is two derivations and a
model spec one, and `codeql-bare`, `codeql-full` without `language` and a spec
in the other kind's field throw. `tryEval` cannot read a message, so a probe
evaluates `lib/customization.nix` over a stand-in engine and greps each refusal.
