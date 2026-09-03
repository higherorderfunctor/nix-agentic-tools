# Steering inclusion modes: what actually loads in the CLI

> **Last verified:** 2026-09-03 (commit pending — first revision. Measured
> against KAS **0.46.1** by reading the extracted `acp-server.js`, cross-checked
> against a live `kiro-cli` 2.21.0 run that reproduced each verdict. Byte
> offsets below are into that 0.46.1 bundle and WILL move on the next bump; the
> mechanisms are what to carry forward, and the re-measure recipe at the end is
> how to re-derive the offsets. They are grep LANDMARKS falling inside the named
> function, not the address of its declaration, so slice BACKWARDS from them as
> the recipe shows. If you change `lib/ai/transformers/kiro.nix`,
> `kiroInclusionOption` in `lib/ai/ai-common.nix`, or bump kiro-cli and this
> fragment is not updated in the same commit, stop and fix it.)

Kiro's public documentation describes the IDE. **Two of the four inclusion modes
behave differently in the CLI, and both differences fail silently** — no error,
no log line, no model-visible marker. This fragment records what the CLI
actually does.

## The one thing to know

There are two `inclusion` enums in the engine, and they are mirror images:

| Enum                               | Where                                           | Values                                        | Who supplies content |
| ---------------------------------- | ----------------------------------------------- | --------------------------------------------- | -------------------- |
| `SteeringContextFrontMatterSchema` | server-side, reads files from disk              | `always` `fileMatch` `manual` `auto`          | the server           |
| `ClientSteeringDescriptorSchema`   | client-side, pushed in over ACP (byte 21517916) | `always` `fileMatch` `manual` — **no `auto`** | the client, inline   |

That split IS the mechanism, and every symptom below follows from it. The server
owns `auto`: it reads the file and the model elects it. The client owns
`manual`: the client is expected to read the file and push its content in
(`content: z.string().max(1e6)`, at most 100 documents). **Kiro's IDE implements
that client half. The CLI does not.**

## Per-mode behavior in the CLI

| Frontmatter                     | Injected      | Model can load           | `#name`      | `/name`        |
| ------------------------------- | ------------- | ------------------------ | ------------ | -------------- |
| `always`, or absent             | every turn    | n/a                      | n/a          | not offered    |
| `manual`                        | never         | no — refused             | literal text | offered, no-op |
| `auto` + `name` + `description` | never         | yes — `disclose_context` | n/a          | works          |
| `fileMatch` + pattern           | on file match | n/a                      | n/a          | not offered    |

`manual` is the row to internalize: it produces a slash command that does
nothing at all, and `#name` stays literal text in the prompt. A `manual`
document in the CLI is not loaded-and-ignored — **it is never read**.

## `disclose_context` serves exactly one pool

The tool's items come from `getVisibleItems()` (byte 19423635) →
`ProgressiveContextManager.getItemsForSession()`. The loader that fills that
pool, `parseProgressiveSteeringFile` (byte 21513972), rejects in two stages:

```js
if (!result.frontMatter || result.frontMatter.inclusion !== "auto") return void 0;
if (!result.frontMatter.description) { logger.warn(...); return void 0; }
```

Two consequences worth stating separately:

- `auto` is the **only** admitted mode. Asking for a `manual` document by name
  returns `No skill or auto inclusion steering file found with name "..."`
  (byte 19429385) — the designed scope surfacing, not a lookup bug. The tool's
  own model-facing description says as much: "Activate skills or auto inclusion
  steering files."
- A missing `description` is a **second hard reject**, not a warning. An `auto`
  document without one is silently absent from the pool.

The lookup key is `frontMatter.name` when present, else the file basename.

## `manual` reaches the client as a pointer nobody dereferences

`createSteeringCommandSource` (byte 21553593) is why `/s-manual` appears at all.
It admits both on-demand modes and mints a command carrying a **path pointer**,
not content:

```js
docs.filter((doc) => doc.config?.inclusion === "manual" || doc.config?.inclusion === "auto")
    .map((doc) => buildCommand(doc.displayName, ..., "steering", {
        contextQuery: `${doc.scope}:${URI.parse(doc.uri).fsPath}`,
        commandId: doc.commandId,
        resource: doc.resource,
    }))
```

**`contextQuery` occurs 4 times in the entire 23 MB bundle** — bytes 21553075,
21553268, 21553286 and 21553788 — and all four are in this construction path.
There is no handler that reads one back. (Positive control: `inclusion` and
`disclose_context` both hit many times in the same file, so the search method
works.) Resolving the pointer is the client's job, and the CLI does not do it.

The other `manual` site, `emitDocumentsChanged` (byte 21491353), only normalizes
a mode label for a notification. It is metadata, not a load path.

This also explains why `/s-auto` works while `/s-manual` does not, despite both
coming from the same filter: the CLI can only activate what is in the
progressive-context pool, and `auto` is the sole mode admitted to it. That last
step is an inference consistent with every observation — the KAS server was read
directly, the CLI binary was not.

## Any frontmatter fault degrades to `always`, silently

`NodeSteeringDocumentSource.parseSteeringFile` (byte 21446732):

```js
try {
  const result = parseFrontMatter({ schema: SteeringContextFrontMatterSchema, content });
  return { content: result.content, config: result.frontMatter ? { ... } : void 0 };
} catch {
  return { content, config: void 0 };
}
```

`parseFrontMatter` (byte 5160318) throws `FrontMatterLoadError` on **either** a
YAML error **or** a Zod validation failure. The catch is bare — no logger call —
and it fails open in three compounding ways:

1. `config: undefined` means no inclusion, which is treated as `always`. A
   scoped document silently becomes an every-turn document.
2. It returns `content`, the ORIGINAL file text, not `result.content`. The
   broken frontmatter block is injected into context **as body text**.
3. Nothing is logged, so there is no signal anywhere that it happened.

A single malformed frontmatter key therefore converts a narrowly-scoped document
into a permanent per-turn context tax, with YAML noise in the body. This is the
most expensive failure mode in the whole surface.

## `fileMatchPattern` YAML shape decides whether scoping works

Measured on kiro-cli 2.21.0 by writing each shape and observing whether the
document injected on every turn (wrong) or only on a matching file (correct):

| `fileMatchPattern` written as         | Result                       |
| ------------------------------------- | ---------------------------- |
| multi-line flow array, trailing comma | injected every turn — BROKEN |
| multi-line flow array, no comma       | injected every turn — BROKEN |
| inline `["a","b"]`                    | correct                      |
| scalar `"a"`                          | correct                      |
| block sequence `- "a"`                | correct, and dprint-stable   |

The two broken shapes take the degrade-to-`always` path above, which is why they
present as an always-loaded document rather than as an error. **The exact parse
fault has not been traced** — only that the consequence is the documented
degrade. Prefer the block sequence: it is the one shape that both parses and
survives formatting unchanged.

**This trap does not reach Nix-managed steering.**
`lib/ai/transformers/kiro.nix` emits a scalar for a single path and an INLINE
array for several, and both of those shapes measured correct. The hazard is
confined to hand-authored steering files.

## What the transformer already guarantees

`lib/ai/transformers/kiro.nix` throws rather than emitting a document that would
vanish or misbehave: an unknown mode, `auto` without a non-empty `name`, `auto`
without a non-empty `description`, and `fileMatch` without paths are all eval
errors. The `auto`-plus-`description` guard in particular is load-bearing
against the two-stage reject above — **do not relax it as redundant
validation**, because the engine's own failure for that case is silent absence
from the pool.

Still open, and deliberately not decided here: whether the repo should keep
accepting `inclusion = "manual"` at all for CLI-targeted output, given that it
can only ever produce a no-op slash command there. It remains correct for IDE
consumers.

## How to re-measure on a bump

The engine ships as plain, readable, comment-bearing JS — not a hostile blob. It
is extracted to a local cache, so do not hardcode the path; recover it:

```bash
kiro-cli acp &                    # then, in another shell:
pgrep -fa acp-server              # the argv names the real acp-server.js
```

That resolves to
`~/.local/share/kiro-cli/kas/<ver>-<sha>/node_modules/@kiro/agent/dist/server/acp-server.js`,
and the `.d.ts` siblings in `dist/` are not minified at all, which makes them
the fastest way to recover structure. The authoritative version is
`@kiro/agent`'s `package.json` version — it is what the server logs at startup,
and it matches neither the CLI version nor the cache directory name.

Two traps when reading it:

- Lines are megabytes long. **Never** run a bounded-context regex against it.
  Get a byte offset, then slice: `command grep -boF 'needle' FILE`, then
  `tail -c +<off-2000> FILE | head -c 6000`.
- `grep` in this environment is ugrep; use `command grep` or `rg`.

The enum consumer census is the cheap regression check — count
`inclusion === "<value>"` per mode. At 0.46.1 it is `always` 4, `fileMatch` 1,
`manual` 2, `auto` 1, with zero `switch` dispatch on `inclusion`. That is
byte-identical to the census taken against KAS 2.15.1 in
[`f15-doc-loading.md`](../../../docs/plans/kiro-v3-research-raw/phase2/f15-doc-loading.md),
so the enum has been stable across six CLI releases. A count that differs means
a consumer moved and the mode table above needs re-deriving.
