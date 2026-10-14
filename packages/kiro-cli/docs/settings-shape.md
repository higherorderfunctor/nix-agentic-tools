## Kiro settings: a flat format with object values, and where the key stops

> **Last verified:** 2026-10-14 — unsupported root reasoning effort warns with a
> native per-model remedy; native inventory extends flatten boundaries;
> repo-readable exceptions are declared and ACP reads persisted engine settings.
> Prompt-file slots preserve null resets and additional workspace roots use
> additive lists across all three configuration methods. Added roots apply
> relative permission rules, but their `.kiro/settings/mcp.json` is ignored;
> evicted workflow owners use fresh cwd authorization for their children and
> detached run rebuilds. Nullable shared worktree policy preserves unspecified
> and explicit false through native lowering; its location template renders per
> session and may not cover the checkout, its root alone is writable, and
> non-derivable Git layouts and failing Git probes degrade instead of failing.

**Settled — do not relitigate:** Native `settings list --all` is not a
substitute for the TUI workspace contract. It reports 60 workspace keys while
the shipped TUI merge allows 23, including in 2.22.1. The TUI project-local
guard follows that consumer. Declared repo-readable native keys are explicit
exceptions, not a union with the broader native settings reads scope.

### Additional workspace roots

`cli.native.settings.chat.additionalDirectories` is a packaged KAS extension.
For repository/devenv scope:

```nix
ai.kiro.cli.native.settings.chat.additionalDirectories = ["../worktrees"];
```

For Home Manager, use an absolute path to avoid resolving beside global
settings:

```nix
ai.kiro.cli.native.settings.chat.additionalDirectories = ["/home/alice/projects/worktrees"];
```

The list contains nonempty strings; Nix path values are refused to avoid copying
writable directories into the store. Nix null omits the setting; empty lists add
nothing. Raw JSON null is invalid. KAS combines global and repository lists with
the protocol roots. Relative global entries resolve beside `settings/cli.json`
under `KIRO_HOME` (or `~/.kiro`); repository entries resolve from the
conversation cwd. Existing ancestors are canonicalized for deduplication,
preserving the first spelling, protocol order and nested roots. Missing
directories are not created.

New conversations and cold resumes resolve current settings. Resident resumes
retain their admitted roots. Saved provenance distinguishes protocol roots from
configured roots, so removing a setting revokes it on a cold resume. Workflow
children inherit the owner's admitted roots; detached children validate against
the owner's current roots. If the vendor evicts an owner, its child, and a
detached run rebuilding its agent registry, resolve current settings and prompt
files from their own cwd and validate saved roots against that result; revoked
roots still fail. Older sessions without provenance treat their saved roots as
protocol roots and cannot reconstruct which were previously configured.

Relative permission rules apply in every admitted root. For built-in modes and
bundled profiles that includes the vendor default `fs_read ./**` allow; custom
agents use their own rules. Default writes still prompt; configure permission
rules to narrow reads or grant writes. Tool policy still checks symlink escapes.
The server patch ignores added roots' `.kiro/settings/mcp.json`; only global and
session-cwd `mcp.json` loads, with cwd overriding a same-named global server.
Custom agent profiles under an added root's `.kiro/agents/` still load and may
declare their own `mcpServers`. Workflow writes and `fileCheck.path` can use the
identical absolute `{{worktree_path}}/.agents/...` path inside an admitted root.
The old `cli.tweaks.relativeFileCheckPaths` option is removed: either boolean
value produces a migration error. The `workflowFileCheckGuidance` prompt slot
remains available; this change does not replace the vendor's absolute-path
guidance.

The setting requires a declarative v3 engine and the managed package. Explicit
`package = null` produces the existing grouped inert-settings warning. A manual
JSON setting combined with an explicit runtime V2 flag bypasses the declarative
guard; that engine does not run this KAS extension.

### Shared sibling-worktree policy

```nix
ai.worktrees.enable = true;
# Optional; this is the default:
ai.worktrees.location = "../{{repo}}-worktrees";
# Optional withdrawal for Kiro:
ai.kiro.worktrees.enable = false;
```

The shared `enable` field is nullable: null is unspecified, not false. A runtime
null inherits the root value; explicit runtime false overrides root true. With
both unset, no `chat.worktrees` key is emitted, so ordinary repository defaults
do not overwrite a user-global enabled policy. The runtime default is off only
when neither settings layer specifies it. An explicit root or runtime false
emits `{ "enable": false }` and can disable a global policy.

`location` is a template with two fixed variables: `{{repo}}`, the primary
checkout's directory name, and `{{primary}}`, its absolute path. A relative
result resolves against `{{primary}}`, so the default is the sibling
`<primary-checkout>-worktrees`. There is no scripting. A runtime null location
inherits the root value. A rendering equal to the primary checkout or one of its
ancestors fails the session, because the grant below would make the checkout
writable; a location inside the checkout is allowed.

Kiro lowers the normalized policy at default priority to
`cli.native.settings.chat.worktrees`. Direct native settings win, including
nested or flat `{ enable = false; }` and null (omit this layer). A non-null
native object needs a boolean `enable` and may add a nonempty string `location`;
other keys are refused. Each settings layer's object replaces lower layers
whole. A static template with any other variable is an eval error naming it; KAS
refuses the same in hand-written JSON when a session starts. Enabled policy
requires V3; explicit package-null use warns through the existing grouped
package warning. Manual native settings combined with runtime V2 still bypass
KAS.

| Runtime | Shared worktrees policy                                 |
| ------- | ------------------------------------------------------- |
| Claude  | Excluded; root value ignored, per-runtime option absent |
| Codex   | Excluded; root value ignored, per-runtime option absent |
| Copilot | Excluded; root value ignored, per-runtime option absent |
| Kimchi  | Excluded; root value ignored, per-runtime option absent |
| Kiro    | Same library, Home Manager and devenv lowering          |

At admission, the packaged KAS finds the primary checkout from Git's common
directory for ordinary and linked checkouts and renders the location there. It
adds that root to the admitted roots without creating it. Membership enables
default reads, and the server patch also grants `fs_write` inside that root
only, through a session-scoped workspace rule: generic
`chat.additionalDirectories` roots and a session cwd outside the policy root
keep the vendor default, where writes prompt. A session started inside the root
(a linked worktree) can write throughout the root. Explicit permission denies
still win over the grant, and tool policy still refuses symlink escapes. Each
session policy (new, loaded or rebuilt for a detached workflow) re-derives the
root from its own cwd and grants it only while it is one of that session's
admitted roots.

Non-Git sessions gain no root and keep the vendor guidance. Layouts without a
derivable primary checkout (submodules, worktrees of a bare clone, separate Git
directories and bare repositories) admit no root and log a `chat.worktrees`
warning, but still select the PR guidance, with a `<path>` placeholder instead
of a destination. A failing Git probe other than "not a git repository" (a bare
clone at `<dir>/.git`, or Git refusing a repository it does not trust) degrades
the same way. Only a malformed `chat.worktrees` value, a location covering the
primary checkout, or a symlink at the rendered destination fails the session.
Admission rejects an existing symlink at the rendered destination, including a
dangling one; explicit additional-directory aliases retain their separate
behavior. This is an admission-time check, not a guarantee against a later
filesystem change. New and cold-resumed sessions recompute roots; resident
sessions retain their admitted roots.

For new conversations, the selected default worktree guidance keeps workflow
ownership of creation and names the admitted destination. It replaces automatic
rebase/fast-forward cleanup with PR creation and user-controlled merging
followed by cleanup. The resolved text remains part of the fixed prompt
snapshot: cold resume can revoke a root while retaining the conversation's
original prose. An explicit `worktreeGuidance` file wins without being
rewritten; root admission remains active. Null selects the policy-aware packaged
guidance.

`cli.tweaks.stripVendorWorktreeSteering` is retired. Both boolean values produce
a named migration error when the runtime is enabled. Use the shared policy or a
custom guidance file instead of deleting the entire vendor paragraph.

### File-backed prompt slots

`cli.native.settings.chat.promptFiles` is a KAS extension, separate from the
measured native and TUI settings registries. It is an opaque flat-setting value
on library, Home Manager and devenv paths:

```nix
ai.kiro.cli.native.settings.chat.promptFiles = {
  identity = ./prompts/identity.txt;
  workflowFileCheckGuidance = "prompts/file-check.txt";
  worktreeGuidance = null;
};
```

Only these three keys are accepted; values are nonempty paths or null. Omitted
slots inherit, while an explicit null restores the selected packaged text, so
recursive null filtering must stop before this object. Repository settings merge
over global settings slot by slot. String paths resolve beside the global
settings file or from the repository session directory respectively; Nix paths
become store paths. Flat dotted spelling receives the same validation and
flatten boundary.

A nonempty mapping requires the effective declared engine to be V3. Explicit
runtime V2 flags can still bypass KAS, including with manually written JSON;
there is no config-reading wrapper that rejects this case. The selected KAS
resolves and persists text once for a new conversation. File edits apply to new
conversations; resumes, workflow children and forks keep the original snapshot.
See [launcher-argv.md](launcher-argv.md) for lifecycle, template semantics and
legacy-session limits.

### Model suggestions

`cli.native.settings.chat.defaultModel` accepts any string and suggests model
slugs from the independently pinned `kiro-model-catalog` package. Its
public-document source, refresh and parsing contract live in
[model-catalog.md](../../kiro-model-catalog/docs/model-catalog.md). The binary
facts under `packages/kiro-cli/extracted/` contain only engine and settings
measurements.

### Flat settings and object values

`~/.kiro/settings/cli.json` is FLAT: its keys are dotted strings, not nested
objects. `cli.native.settings` lets you write the nested Nix that reads
naturally and `flattenKiroSettings` lowers it:

```nix
{ mcp.loadedBefore = true; chat.enableTangentMode = true; }
# -> {"mcp.loadedBefore": true, "chat.enableTangentMode": true}
```

The trap is that **flat keys do not imply scalar values.** `chat.modelDefaults`
is one key whose value is an object of per-model records. Attrset shape alone
cannot tell that apart from two more levels of grouping, so a walk that flattens
everything writes

```json
{ "chat.modelDefaults.claude-opus-5.effort": "high" }
```

which kiro never matches — it compares the literal key it reads. Nothing errors;
the setting simply does not exist. That held on BOTH backends, so the option was
not a devenv-scope problem, it was unusable.

### The boundary is extracted, not guessed

`aiCommon.flattenDotKeysUntil` takes a list of dotted paths that are complete
setting keys and stops recursing the moment the accumulated path is one of them.
`mkKiro.nix` passes `kiroSettingKeys` — the union of three measured lists from
the `packages/kiro-cli/extracted/` facts, read through `lib.extracted` (each
host's raw measures them; consumers read the merged value):

- `nativeSettingKeys`: the native JSON inventory from
  `settings list --all --format json`, measured with isolated state. This
  preserves object-valued keys such as `api.cps.service`; it does not infer
  types from descriptions or expand the TUI allowlist.
- `settingKeys`: the bundle's own `SCREAMING -> "dotted.key"` registry, 55 keys
  at 2.23.0, all `chat.*`.
- `workspaceOverridableSettings`: the workspace allowlist, which adds 21 keys
  the registry omits — the whole `toolSearch.*`, `compaction.*` and
  `knowledge.*` families, plus ten `chat.*` keys including
  `chat.enableTangentMode`. That last one is the extractor's own PROBE anchor,
  which makes it the sharpest available evidence that the registry is not the
  settings universe: the probe the allowlist scan keys off is itself absent from
  the registry scan.

No single list covers the format, which is why the extractor reports them
separately and the union is taken at the consumer. Since 2.23.0 the chat binary
materializes its compressed TUI source on first launch. The extractor's runtime
build requires a Nix sandbox, a fake KAS, and isolated state; CI explicitly
enables and checks the sandbox on both platforms. HOME/XDG isolation alone does
not prevent native credential discovery from reaching host facilities. To
accommodate platform-dependent state layouts, it finds a unique TUI asset
beneath the isolated state root and accepts it only after its SHA-256 matches
the binary's materialized checksum. TypeScript AST checks then locate the
registry, the allowlist, and the workspace merge that uses it. The two validated
expressions and the selected merge helper are evaluated with inert loaders and
dynamic code generation disabled.

`flattenDotKeys` is now `flattenDotKeysUntil []` — the historical
flatten-everything behavior, unchanged for anything that does not pass a
boundary.

This per-model object is also why `ai.kiro.settings.reasoningEffort` does not
exist. Kiro has no global persisted effort key: lowering one portable scalar
would mean choosing a model, or writing it into every model's record. Both
change what the user asked for. So the factory leaves `settings` out of its
`supportedPools`, and an unsupported pool declares no per-runtime option. The
root `ai.settings.reasoningEffort` warns for Kiro because its persisted effort
is per-model, with no lossless target for a shared scalar. Use
`ai.kiro.cli.native.settings.chat.modelDefaults.<model>.effort` for the native
per-model value, or Kiro's session-only `--effort` flag when persistence is not
wanted.

### What this does and does not fix

It fixes the WRITTEN SHAPE. A key still has to be one kiro honors at that scope:
under devenv the workspace allowlist applies on top, so `chat.modelDefaults`
works there and `telemetry.enabled` does not. See
[`workflow-gating.md`](workflow-gating.md) for that half.

It also removes a misleading diagnostic. The devenv workspace guard reports the
WRITTEN key, so before the boundary existed it named
`chat.modelDefaults.claude-opus-5.effort` as a rejected key — true, but the
fault was the flattener walking past the key, not the allowlist. The two now
agree by construction.

### If a future setting is still written wrong

The boundary knows measured keys and explicit KAS extensions. A setting absent
from those lists flattens all the way, so an object-valued one added outside the
registry would regress silently — the same failure this fixed, in a key nobody
measured. `module-kiro-devenv-object-valued-setting-stays-nested` and its HM
twin pin the behavior; `module-kiro-scalar-setting-still-flattens` is the
control that the walk does not stop EARLY, which would write nested
`{"chat":{...}}` that kiro cannot read either.

### Native startup settings and defaults

`chat.agentEngine` is nullable and typed as `v1`, `v2` or `v3`; `chat.ui` is
nullable and typed as `legacy` or `tui`. Freeform settings and typed keybindings
remain available. Native repository settings override global values for these
two repo-readable keys, so the declared `nativeRepoSettings` admits them
separately from the TUI allowlist. Settings precedence alone does not establish
which UI launches.

For pinned 2.29.1 on Linux, a PTY probe with `chat.agentEngine = "v3"` observed
successful `execve` of Bun running `tui.js chat` in four cases: no UI setting,
global `legacy` with repository `tui`, global `tui` with repository `legacy`,
and explicit `--tui`. Thus persisted `chat.ui = "legacy"` did not select the
classic UI in the measured V3 path. Explicit `--legacy-ui` with V3 instead
exited 1 with an unsupported-combination diagnostic. The probe isolated network
access and used the existing fake KAS fixture. Bun subsequently aborted, so this
establishes dispatch only, not UI health. Darwin and other engines were not
measured. No UI default or upstream dispatch policy is changed here.

Managed configurations default the engine to V3 through the settings writer. An
explicit native null leaves selection to Kiro. Terminal CLI flags override
persisted choices. ACP reads the same engine settings through the existing
package build launchers because ACP does not consult persisted engine settings.
The bare package retains upstream terminal defaults. See
[launcher-argv.md](launcher-argv.md) for precedence, opt-out semantics and
platform composition.

Delegate-routing workflow visibility and module engine warnings reuse the Kiro
declared-engine resolver. Flat keys take precedence over nested defaults,
including explicit null, exactly as in delivered settings.
