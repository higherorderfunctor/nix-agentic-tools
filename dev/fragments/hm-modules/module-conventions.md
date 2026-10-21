## HM Module Conventions

> **Last verified:** 2026-10-20 — the services reconcile entry follows
> `reloadSystemd`; glab resolves redact references at service runtime; non-AI
> owners use the layer-1 helper; Claude uses engine-backed `rw` ownership, Kiro
> stages settings and hooks and drains all three legacy ledgers through the
> engine; Kimchi stages every surface and drains all legacy ledgers, and Claude
> has an ordered activation mode command; Codex stages daemon JSON as `ro` and
> drains legacy ledgers even while disabled; `mkSkillFiles` interpolates every
> skill source before the files engine walks it; Kiro is gated by
> `ai.kiro.cli.enable`; factories read the derived, read-only `ai.kiro.enable`;
> `ai.copilot` is github.com Copilot, with pools under `ai.copilot.github` and
> no launcher. ai-module supplies the sole file writer and its ordered prune and
> apply entries; legacy ledgers remain available for upgrades.
>
> Full lineage:
> `git show 25ec0738:dev/fragments/hm-modules/module-conventions.md`.

These conventions are enforced by code review and owner-local module evaluation
tests, not by the module system itself. Follow them when adding or modifying any
HM module under `modules/**`.

### Option shape conventions

**Use explicit types.** Rare `types.anything` appears only as an
`internal = true` escape hatch in the MCP module's `mcpConfig`. Everywhere else,
declare the real type: `types.submodule`, `types.nullOr`, `types.attrsOf`,
`types.enum`, `types.attrTag`, `types.listOf`, etc.

**Submodules as containers.** Per-ecosystem config lives in a submodule:
`ai.claude`, `ai.codex`, `ai.copilot`, `ai.kimchi`, and `ai.kiro` are
`types.submodule` containers. Kiro keeps shared file options and the derived,
read-only `enable` at `ai.kiro`; its launcher options (`enable`, `package`,
`environmentVariables`, `shell`, `native.settings`, and other CLI controls) live
under `ai.kiro.cli`. Copilot keeps its pools under `ai.copilot.github`. Other
runtimes keep launcher and pool options at their runtime root. The submodule is
the logical grouping — do not flatten per-ecosystem options into the top level.

**Flat at top level for cross-ecosystem.** `ai.context`, `ai.rules`,
`ai.skills`, and `ai.environmentVariables` are NOT nested inside a per-ecosystem
submodule. They fan out to whichever ecosystems are enabled at `mkDefault`
priority. Anything that's "one option, many destinations" lives flat.

**Keep normalized and native settings separate.** `ai.<runtime>.settings` is a
closed normalized submodule for runtimes that support the settings pool; Kiro
excludes that pool. Runtime-shaped passthrough belongs under
`ai.<runtime>.native.settings` (`ai.kiro.cli.native.settings` for Kiro); when
wrapping a CLI's native settings file, use `freeformType = jsonFormat.type` plus
explicit `mkOption` declarations for known typed keys (for example,
`native.settings.model` and `native.settings.telemetry`). Unknown native keys
flow through freely; known keys get type-checked. Do not add runtime-native keys
to normalized `settings`.

**Defaults via `mkOption { default = ...; }`**, not `mkDefault` in the
declaration. Reserve `mkDefault` for fanout values in the config block (so
consumers can override).

### Gating and mkIf patterns

**Per-CLI enable is the SOLE gate.** Consumers set
`ai.{claude,codex,copilot,kimchi}.enable` or `ai.kiro.cli.enable`. Factories
read `ai.<runtime>.enable` in their mkIf blocks; Kiro derives that read-only
value from its CLI switch. There is **no master `ai.enable`** — it was dropped
in commit f2e911c after causing a silent no-op bug (see `ai-module-fanout`
fragment for the full story).

The `config` block shape:

```nix
config = mkMerge [
  { assertions = [...]; }                # Always evaluated
  (mkIf cfg.claude.enable  { ... })      # Each CLI independent
  (mkIf cfg.codex.enable   { ... })
  (mkIf cfg.copilot.enable { ... })
  (mkIf cfg.kimchi.enable  { ... })
  (mkIf cfg.kiro.enable    { ... })
];
```

**No per-CLI block flips an upstream `programs.<cli>.enable`.** Every runtime
installs its package through the shared backend transform and delivers its files
through `ai.<runtime>.files`, so a consumer sets the launcher switch once and
there is no second module to import, enable or keep in step.

### Assertion conventions

**Always outside mkIf.** Assertions live in an unguarded block inside
`mkMerge [...]`. This ensures misconfigurations surface even when the feature
itself isn't enabled:

```nix
config = mkMerge [
  {
    # ILLUSTRATIVE ONLY — the shape, not a real assertion of this repo.
    assertions = [
      { assertion = cfg.claude.plugins == {} || cfg.claude.enable;
        message = "ai.claude.plugins is set but ai.claude.enable is false."; }
      # ...
    ];
  }
  # ... mkIf blocks ...
];
```

**Precise messages naming the option path.** Don't say "module error" or
"configuration invalid." Say
`ai.claude.plugins.<name> would land at ~/.claude/skills/<name>, which an ai.skills entry already owns`.

### Package override pattern

**Every runtime with a launcher exposes a `package` option.** Kiro uses
`ai.kiro.cli.package`; other runtimes use `ai.<runtime>.package`; github.com
Copilot has no launcher and no package. Consumers can swap out the package
entirely. In this example, `cfg` denotes that launcher subtree (kiro-cli; Claude
has no wrapper):

```nix
pkgs.symlinkJoin {
  name = "<cli>-wrapped";
  paths = [cfg.package];
  postBuild = ''
    mv $out/bin/<cli> $out/bin/.<cli>-wrapped
    cat > $out/bin/<cli> << 'WRAPPER'
    #!/usr/bin/env bash
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    # ...env exports, path setup, etc.
    exec "$out/bin/.<cli>-wrapped" "$@"
    WRAPPER
    chmod +x $out/bin/<cli>
  '';
}
```

**Every module site reads this flake's roots from `config.ai.internal.roots`,
never from raw `pkgs`.** That covers every root the packages claim: `ai`,
`docs`, `stacked-workflows-content`, `delegate-routing-content`.
`config.ai.internal.packages` is `roots.ai`. The flake wrappers
(`homeManagerModules.default`, `devenvModules`, the repo's `devenv.nix`) set
`ai.internal = repository.moduleInternals`, whose `rootsFor` (in
`lib/facets/repository.nix`) returns each root from the consumer's `pkgs` when
this flake's overlay is applied, else this flake's own build (`natSets`) wrapped
by `checkedBy pkgs`, so the module's own nixpkgs decides unfree. So a module
default is the same derivation as the overlay attribute and as
`packages.<name>`, and a consumer's own `pkgs.ai.X` override still reaches it.
The routing shapes:

- runtime modules, and the shared AGENTS.md writer's guards, pass
  `pkgs = pkgs // {ai = config.ai.internal.packages;}` to their factory; the
  factories stay public and read the `pkgs` given;
- skill packages (stacked-workflows, delegate-routing, kimchi-docs) read
  `config.ai.internal.roots.<root>`; their `skills` / `rules` lambdas take
  `config` for it;
- git tool records take `package = ai: ai.gitTools.<tool>`, which
  `lib/git-tool-settings/tool-module.nix` applies;
- the guards table and single sites (glab, beads, semble, mcp-services, the
  git-branchless init task) read `config.ai.internal.packages.<path>` directly.

`defaultText` comes from `lib/ai/nat-package-text.nix "<path>"` (runtime records
set `defaults.packageText`), so the wording lives in one place. Public library
factories (`mk*Mcp`, `mkSemble`, `lib.ai.guards`) still take the caller's
`pkgs`.

### Optional cross-module contributions

A standalone package module must remain importable without the umbrella AI
module. Before contributing integration state such as a Codex writable root,
test the destination container with `lib.hasAttrByPath ... options`, then gate
on the relevant runtime enable. Such plumbing belongs under an internal, hidden
option rather than either public settings surface; Codex uses
`ai.codex.internal._integration_writable_roots`. glab uses this pattern to
contribute its effective `configDir`: Home Manager resolves its `null` default
to `${config.xdg.configHome}/glab-cli`, while devenv uses its evaluated project
state default or the consumer's explicit override. The contribution configures
an already-enabled Codex; it never enables Codex itself.

### Activation script patterns

**Location and ordering:** owners declare commands at layer 1, never
`home.activation` (`ai-module-no-direct-sink-writes` fails a module line that
starts with one):

```nix
ai.<owner>.activation.<name> = {
  after = ["files"]; # abstract points: files, linkCheck, materialized, secrets, shell
  command = script;
};
```

File application runs after `linkGeneration`, once Home Manager has linked the
generation into the home directory. `writeBoundary` alone does not establish
that ordering. ai-module supplies `files-prune` before `checkLinkTargets` and
`files-apply` after linking; apply depends on prune. Prune clears a retiring
copy before a native link checks its destination. Producers state entries and
abstract activation points rather than declaring writer bundles.

`exit` semantics for layer-1 commands: see `packages/ai-module/docs/contract.md`
(Activation).

**Owned leaves for state documents:** Claude's `~/.claude.json` keeps
harness-written state beside Nix-owned leaves. Its factory stages a JSON `rw`
document through `_generatedFiles`; the files engine asserts declared leaves,
retracts retired leaves and preserves unowned state. Kimchi stages both user
documents through the same engine with `method = "rw"`; its old document helper
and writer are deleted. Kimchi's user `config.json` and `harness/settings.json`
are documents because `/login` and `/model` write into them (settled 2026-09-30
after a read-only copy locked `/login` out); its `mcp.json`, `permissions.json`
and `trust.json` stay read-only copies. A blind `jq -s '.[0] * .[1]'` cannot do
the middle one: it has no way to tell a native key from a Nix key that was
deleted. Only a STATE file the harness must keep writing is a document; a file
whose every key is configuration is a read-only copy.

The engine JSON codec preserves leading full-line `//` comments. It tracks
declared keys, restores changed leaves and retires removed leaves while keeping
native keys. A document created by the engine is removed only when retirement
leaves it empty; legacy-imported documents stay because their creation
provenance is unknown. `ai-module-files-rw-runtime`,
`ai-activation-settings-mode` and `ai-module-kimchi-settings` exercise these
cases on real directories.

The files engine publishes each file atomically and saves ownership state for
idempotent re-runs. It has no activation rollback or compare-and-swap retry for
concurrent native writers; those are outside the engine MVP.

A new `rw` document defaults to 0600; an existing one loses group/other access.
Claude also declares `activation.claude-config-mode` after `materialized`,
because its empty unpin map omits the document but still needs mode repair. The
command skips symlinks and missing files. `ai-activation-settings-mode` executes
the actual HM bodies with both nonempty and empty declarations.

The merged `ai.files` map is the eval-visible delivery plan. Checks read it
directly or use the plan-aware `harness.ownedDocument` reader. Callers supply
content, format and method; backend lowering owns the generated scripts and
state. Reading a plan derivation back at evaluation would be
import-from-derivation.

Do not generalize documents to every file or runtime. A store symlink is
preferred wherever the CLI's own save fails cleanly against one: Codex's
`config.toml`, user and project, is a symlink because every Codex config writer
writes its temporary beside the link's target and so refuses the save
(`chatgpt-codex-readonly-config`). A CLI that renames over the path gets a
read-only copy instead, as Codex's daemon `settings.json` does.

**Parity does not require identical delivery paths.**
`ai.codex.execpolicyRules.<name>` is one typed option schema in HM and devenv,
but HM writes each `.rules` file into the user-global `${configDir}` while
devenv writes the project-local `.codex/rules/<name>.rules` instead — Codex
reads both layers natively. This replaces the whole-file `ai.codex.profiles`
layer as the worked example: that option and its devenv `CODEX_HOME`
materializer were removed 2026-09-19 as unreachable dead code (see the Settled
bullet in `dev/fragments/ai-module/ai-module-fanout.md`).

**Staged settings retire through the files engine.** Codex stages its Home
Manager daemon `settings.json` as JSON with method `ro` whenever enabled,
including an empty declaration. The imperative daemon settings writer is gone.
Its `migrationConfig` declares `codex-daemon-settings` on Home Manager and
`codex-execpolicy` on both backends in `legacyLedgers`, outside the enable gate.
An owner disabled at its first upgrade therefore still drains the old ledgers;
the files engine retires copies when their declarations disappear. Kimchi stages
its shared documents as `rw` and remaining settings copies as `ro`, with every
legacy ledger declared even while disabled. Kiro stages both settings files as
`ro`: Home Manager owns even empty values, while devenv emits only declared
project settings. Its hook copies retire through the same engine, and all three
old ledgers stay declared while Kiro is disabled.

Devenv-side writes are otherwise unconditional (always write the file when
`enable = true`): devenv deliveries are project-local links or engine copies,
not home-dir writes. Claude is the exception. Its devenv `.claude/settings.json`
and `.mcp.json` are emitted only when non-empty, because either one would shadow
a project's own committed file, so an empty declaration writes nothing there.
Kiro and Kimchi are the other exceptions: Kiro's project `settings/cli.json` and
`settings/mcp.json` and Kimchi's project settings copies are claimed only when
something is declared, so enabling the runtime does not take over and back up
those files.

**Secrets at activation time, not eval time.** Sops-nix paths
(`cfg.userId.file`) are read by the activation script at run time via
`cat "$path"`. Do NOT `builtins.readFile` them at eval time — sops decryption
happens after nix eval finishes.

**A prompt-capable user service needs a consumable activation marker.** glab's
keyring synchronization does not invoke Secret Service directly from Home
Manager activation, which may run headlessly during a NixOS rebuild. Activation
creates a non-secret XDG-state marker; a systemd path unit wanted by
`graphical-session.target` consumes it through a `Type=oneshot` service. The
service removes the marker on success, cancellation, timeout, and failure and
sets `Restart=no`. Without that consume-on-every-exit invariant, a still-true
`PathExists` condition immediately reactivates a failed service and turns one
keyring unlock prompt into a loop.

Probe Secret Service BEFORE reading the real secret. glab deliberately falls
back to plaintext `config.yml` storage when no keyring backend is available. The
synchronizer therefore writes and removes a harmless libsecret sentinel first;
cancellation fails before the redact token reference is resolved. The ordinary
wrapper also omits `GITLAB_TOKEN` in this mode because environment credentials
take precedence over the stored keyring value.

### Files and activation through ai-module

Owners import `packages/ai-module/lib/runtime.nix`, then state final content,
format and method in `ai.<owner>.files` or finite commands in
`ai.<owner>.activation`. Only ai-module writes native file and activation sinks;
`ai-module-no-direct-sink-writes` fails a library or owner module line that
starts with one. The layer contract is `packages/ai-module/docs/contract.md`.
Semble's cache guard follows `materialized`; glab's keyring marker follows
`files` and `secrets`; the services reconcile entry also follows
`reloadSystemd`, through `afterNodes`. HM lowering wraps the whole command in
`run`; child command bodies use ordinary external commands, not activation-shell
functions. Package installs keep their native configuration surfaces; daemons go
through `ai.services`. `outOfStoreSymlink` is not used.

### Config parity rule (HM ↔ devenv)

**Every shared configuration option on an HM module under `modules/<subdir>/`
MUST have a matching option on the corresponding devenv module under
`modules/devenv/<subdir>.nix`** — same types, same semantics, same fanout
behavior. If you add an option to one, add it to the other in the same commit.
`checks/modules/options-doc.nix` enforces exact flattened option-name and type
parity across the full generated `ai.*` trees; module-eval tests cover
backend-specific lowering and diagnostics.

**Shared types live in `lib/`.** Both HM and devenv modules import types from
`lib/ai/ai-common.nix` (such as `ruleModule`) so the surfaces stay in sync by
construction.

**Stronger than shared types: one shared DECLARATION.** `packages/glab` puts its
entire `options.glab` block in `packages/glab/modules/options.nix` and both
facets `imports` it, so the two surfaces are the same expression rather than two
that currently agree. Prefer this when the declaration is shared even if backend
lowering differs: glab's HM file owns package installation and optional keyring
lifecycle, while devenv installs the package and explicitly rejects that
user-session lifecycle. `packages/glab/checks/module-eval.nix` asserts the two
option trees are equal (`module-glab-hm-devenv-option-parity`), which is a real
test rather than a code-review convention.

Note this is NOT free for every module: it only works when the options carry no
facet-specific defaults or `defaultText`. Modules whose options reference
`home.` or `files.` paths still need the per-facet declaration.

`packages/semble` takes the pattern one step further: one program specification
feeds the shared factory, and one shared runtime-fanout module is parameterized
by package installation and cache location. Both backends declare cache
invalidation through `ai.semble.activation`, after `materialized`. Feature and
runtime selection therefore cannot drift between backends. Runtime selection
contributes defaults to `ai.<runtime>.*` but deliberately does not set
`ai.<runtime>.enable`; choosing an integration is not authority to enable the
corresponding CLI.

The same shared declaration owns Semble's validation boundary. Invalid content
sets become module assertions with stable messages in both facets, while the
direct `mkSemble` helper throws those same messages because no module evaluator
would consume an `assertions` result there. Kiro-only agent-scoped MCP isolation
is likewise an explicit assertion; unsupported runtimes never degrade to a
root-visible server.

`lib/ai/mkSkillPackageModule` applies the same shared-declaration rule to
stacked-workflows. Both facets expose `ai.programs.<name>.enable` and every
registered per-runtime override from one enable-only program specification, then
write the resolved package content into that backend evaluation's per-runtime
pools. A runtime false therefore removes only that runtime's skill/rule
contribution.

`stacked-workflows.gitPreset` is the deliberate companion exception. It stays
outside `ai.*`, is declared once (`modules/options.nix`) for both backends, and
only sets `mkDefault` values on the `git.*` options (packages/git/docs/git.md),
which Home Manager delivers through `programs.git.settings` and devenv as one
repository-local include. Putting it in the program specification would generate
per-runtime Git-preset overrides that have no coherent lowering. The normalized
program tree itself remains exactly parity-checked.

Both sinks wrap every Semble entry point with its selected cache location. Home
Manager deliberately fixes the user-global root at
`${config.xdg.cacheHome}/semble`, including on Darwin where Semble's native
platform default differs; devenv fixes the project root under its state
directory. Runtime states that resolve to one customized derivation share its
wrapper and the established cache root. Divergent `package`, `grammars`,
`pathMappings` or model-routing values produce package-keyed cache directories
and one collision-free installed aggregate: generated guidance uses
runtime-specific CLI aliases, while MCP commands point at their exact wrappers.
The activation guards therefore clear and stamp the same variant indexes the
installed CLI and MCP servers use. Customized packages also stamp their grammar
and mapping fingerprint into index metadata, protecting package-only consumers
that do not use either module's activation guard.

**Intentional differences** exist and are NOT parity gaps:

- Non-AI layer-1 lifecycle namespaces exist on their native backend: `ai.glab`
  and `ai.mcp-services` on HM; `ai.beads`, `ai.git` and `ai.git-branchless` on
  devenv. Option docs retain them and check their presence explicitly outside
  shared runtime and pool parity.
- ai-module lowers owner entries to `home.file` / `home.activation` on HM and
  `files.*` / `tasks.*` on devenv (per-project writable tree, not home dir);
  owners write neither
- glab's `keyringSync` declaration exists in both facets, but devenv rejects
  enabling it: repository shells may consume global keyring state, while login,
  Secret Service, and graphical-session lifecycle belong to Home Manager
- Scope-only behavior remains declared in both trees and fails explicitly where
  unsupported. For example, `ai.copilot.github.projectDir` has one shared
  declaration; devenv consumes it, while Home Manager rejects non-default
  overrides because it has no project root. Do not encode that boundary by
  deleting the HM option.

If you touch one and the other is "intentionally different," say so in the
commit message. If the mismatch is accidental, it's a bug.

### Validation

Owner-local module tests use `lib/testing/module-harness.nix`, which evaluates
the same discovered Home Manager and devenv module sets as production. It
injects stubbed `pkgs.ai` by default, which `ai.internal.roots` prefers;
`injectAi = false` evaluates over `pkgs` as given, so a site still reading a
root from raw `pkgs` throws instead of passing on stubs. Root check concerns own
cross-package contracts. Add a case in the SAME commit whenever it (a) adds or
removes an option under `modules/**` or `lib/ai/**`, (b) changes what an
existing option's `mkIf` writes into `config`, or (c) adds, removes or changes
the condition of an assertion. A commit that touches `modules/**` but does none
of those — a rename, a comment, formatting, a refactor with identical evaluated
`config` — needs no new case. The three map onto:

- Option discoverability (set an option, verify it evaluates)
- Fanout correctness (set an option, verify it propagates)
- Assertion firing (intentionally misconfigure, verify the right assertion
  triggers)

The tests caught the `ai.enable` master-switch bug during the f2e911c fix
because the post-fix tests didn't reference `ai.enable` anymore. Regression
protection via the eval harness.

**Eval-only checks DON'T catch everything.** Some bugs only manifest during real
HM activation against real consumer state (e.g., the Nix path type strictness
bug below). A diff that changes an `ai.<owner>.activation` command, adds or
removes an `ai.<owner>.files` or staged `_generatedFiles` entry, or changes
`packages/ai-module/lib/lower-hm.nix` or `packages/ai-module/lib/files/**` is
therefore NOT fully covered by a green `nix flake check`.

**Do not run `home-manager switch` yourself — it mutates the operator's live
system.** Instead add a line to the PR description naming the activation entries
or file paths the change touches, and ask the operator to run
`home-manager switch -b backup` before merge. For every other diff under
`modules/**`, a green `nix flake check` is the complete bar.

### Nix path types — strict `lib.isPath` checks

**Filter/copy operations on source paths return STRINGS, not path-typed
values.** Only `./` path literals in Nix source produce `builtins.typeOf` result
`"path"`. Everything that copies a source into the store returns a store-path
string:

| Form                                     | `typeOf` result              |
| ---------------------------------------- | ---------------------------- |
| `./path/to/x` (literal)                  | `"path"`                     |
| `./x + "/suffix"` (path addition)        | `"path"`                     |
| `builtins.path { path = ./x; ... }`      | `"string"` (store path)      |
| `builtins.filterSource f ./x`            | `"string"` (store path)      |
| `lib.cleanSourceWith { ... }`            | `"set"` with `.outPath` str  |
| `builtins.storePath "/nix/store/..."`    | `"string"`                   |
| `"${./x}/suffix"` (string interpolation) | `"string"`                   |
| `pkg.passthru.foo = ./x` then read back  | usually `"string"` (coerced) |

This matters when passing values to options that gate on `lib.isPath` or
`builtins.isPath`:

- **Skill trees.** Both backends go through
  `lib/ai/hm-helpers.nix:mkSkillFiles`, which asks `builtins.readFileType` —
  agnostic to path versus string — and interpolates the source, so the files
  engine walks one store path either way. That is why skill packages can feed
  store-path strings through `lib/ai/mkSkillPackageModule.nix`. Our helper
  checked the strict `lib.isPath` until commit `1f1ad35`, and a string input
  fell through to writing the value as **TEXT CONTENT** to
  `.claude/skills/<name>/SKILL.md` — a single line like
  `/nix/store/abc-skills/stack-fix` instead of real YAML frontmatter, so Claude
  couldn't load the skill.

**How to apply.** Skills take either form (path literal OR store-path string),
so the skill packages deliberately use strings. But the type distinction still
bites for values flowing into sinks that gate on the STRICT `lib.isPath` —
`cfg.context` writes a string as **text**, not a symlink. (`mkSourceEntry`, the
helper this used to name first, is deleted: its last caller was the single-file
skill branch, which now states `content.source` unconditionally.) When the
sink's tolerance is unknown, the safe form is a `./` path literal (introduce a
module-relative one in the `let` block so filtering doesn't coerce it to a
string):

```nix
{ ... }: let
  # Literal path, relative to THIS module file. Resolves at
  # parse time, retains `"path"` type through addition.
  skillsRepo = ../../packages/foo/skills;
in {
  config = mkIf cfg.enable {
    ai.skills = {
      # `path + "/suffix"` returns a path (type preserved)
      bar = skillsRepo + "/bar";
    };
  };
}
```

**Historical failure mode.** Surfaced 2026-04-08 during skills-fanout-fix Task
3: the stacked-workflows HM module used
`swsContent.passthru.skillsDir + "/stack-*"` where `skillsDir` came from
`builtins.path` (a string). Against the then-strict Home Manager `mkSkillEntry`,
every consumer had garbage `~/.claude/skills/stack-*/SKILL.md` files (the store
path written as text) for weeks. Worked around in commit `5a14a0c` with a
module-relative `skillsRepo` path literal; the root cause is gone now that every
skill goes through `mkSkillFiles` (above).

**`mkSkillFiles` is string-tolerant.** It accepts path-typed values AND
store-path strings. A generated store-path string remains a supported,
deliberate pattern even though this repository no longer ships a first-party
producer. Reserve the `./`-literal discipline for the strict-`isPath` sinks
noted above.
