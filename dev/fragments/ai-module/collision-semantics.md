## ai.\* Collision Semantics

> **Last verified:** 2026-08-15 (commit pending — collision checks now follow
> each app record's `supportedPools`: unsupported root fanout degrades without a
> collision assertion because the corresponding per-runtime option does not
> exist). Prior: 2026-08-14 (commit pending — records where a MODULE may
> contribute, now that `lib/ai/mkSkillPackageModule.nix` writes the per-CLI
> pools. That looks like the exact shape `shell-option.md` bans, and the
> discriminator — always-on default versus opt-in behind an explicit enable — is
> written down in the new section below because the ban's reasoning does not
> carry across it. Also records the provenance guard, which makes the root-write
> prohibition structural rather than reviewed-for). Prior: 2026-08-10 (commit
> pending — TWO corrections. The call site was never `hmTransform.nix` +
> `devenvTransform.nix`; both are 16-line re-exports of
> `mkBackendTransform.nix`, which is where the merge AND the per-CLI baseline
> option surface actually live, so step 2 of the checklist pointed at files that
> declare nothing. And `ai.shell` now exists as a deliberate scalar EXCEPTION
> resolving override-wins rather than collision-as-failure — recorded here so it
> is not "fixed" into the covered pools table). Prior: 2026-08-04 (commit
> pending — kiro's `agents` is still the CLI-specific-shape exemplar, but it is
> a typed record now rather than raw JSON). Prior: 2026-08-01 (commit pending —
> distinguishes portable hooks, whose per-event matcher-group lists
> intentionally append, from key-identity pools). Prior: 2026-04-21 (commit
> pending — refactor of ai-factory-collision plan §3.2). If you add a new shared
> pool to `ai.*` or change how pools are merged across the L2↔L3 boundary and
> this fragment isn't updated in the same commit, stop and fix it.

### Rule

Duplicate keys across any shared `ai.*` pool are a **failure condition**, not a
silent override. The factory used to merge the top-level pool with the per-CLI
pool via `config.ai.<pool> // cfg.<pool>`, letting a later per-CLI contribution
silently overwrite a same-name top-level entry. User directive: "mixing and
collision should be a failure. we don't merge over keys."

This rule applies only where a runtime supports the pool. Unsupported
per-runtime options are absent, and root fanout to that runtime degrades before
any merge or collision check.

### Where a MODULE in this repo may contribute

Consumers write whichever level they like. This repo's own modules may not: they
write `ai.<cli>.<pool>` and **never** the root `ai.<pool>`, enforced by the
provenance guard in `checks/module-eval.nix` (`rootPoolViolations`), which reads
each root option's `definitionsWithLocations` and fails when a definition came
from a file inside this flake. A consumer's inline config reports
`<unknown-file>` and is therefore always allowed — the root level is theirs.

The reason is not symmetry. Root pools are ADDITIVE and cannot be retracted per
runtime, so once per-runtime negation exists a root contribution makes a
consumer's negation evaluate perfectly cleanly and silently fail to negate
anything. No error, no warning, and no visible difference except the feature
they turned off still being on.

**This is in tension with `shell-option.md`'s "a module must NEVER contribute
into `ai.<cli>.environmentVariables`", and the tension is real rather than a
contradiction.** Both statements are about the same mechanism: `intersectAttrs`
compares KEY PRESENCE and cannot see `mkDefault`, so a module contribution to a
per-CLI pool turns a consumer's same-key root entry into a hard eval failure
rather than yielding to it. The discriminator is **who pays**:

| module contribution                                         | reaches                  | a consumer's same-key root write                                            |
| ----------------------------------------------------------- | ------------------------ | --------------------------------------------------------------------------- |
| always-on default (`gitSshConfigWorkaround`)                | every consumer, unasked  | explodes on config nobody opted into — BANNED                               |
| opt-in behind an explicit `enable` (`mkSkillPackageModule`) | only consumers who asked | explodes on config that consumer chose — ACCEPTED, documented at the option |

An always-on default that collides is a trap: the consumer never asked for the
contribution and the error names a pool they never wrote. An opt-in package's
contribution is something the consumer switched on deliberately, so trading the
root override for a per-runtime one (`ai.<runtime>.skills.<name>`) is a
documented interface, not an ambush. `lib/ai/mkSkillPackageModule.nix` states
that override key in its header; if you move a module's writes per-CLI, state it
in yours too.

`ai.instructions` is asymmetric here and it matters: it is a LIST that
concatenates with no collision check, while `skills` is an attrset that is
collision-checked. Two writes on adjacent lines can carry different risk.

### Covered pools

Applies to every attrset-shaped shared pool in `ai.*`:

- `ai.rules` / `ai.<cli>.rules`
- `ai.skills` / `ai.<cli>.skills`
- `ai.mcpServers` / `ai.<cli>.mcpServers`
- `ai.lspServers` / `ai.<cli>.lspServers`
- `ai.environmentVariables` / `ai.<cli>.environmentVariables`
- `ai.agents` / `ai.<cli>.agents`

`ai.instructions` is a list, not an attrset, so list concat stays as-is.
`ai.context` is single-valued.

`ai.shell` is the deliberate SCALAR exception and resolves the other way —
per-runtime silently overrides the root, via `resolveOverride` rather than
`mergeWithCollisionCheck`. A pool key names an independent entry, so overriding
one loses data; a nullable scalar has nothing to lose, and making the pair
collide would leave no way to express "this default, except here". See
`shell-option.md`, and do not "fix" it into the table above.

`ai.hooks` is the deliberate attrset exception: event keys identify additive
lifecycle streams, not replaceable entries. For a shared and runtime-specific
definition of the same event, matcher-group lists concatenate in shared-first
order. The top-level event vocabulary is restricted to the portable Claude/Codex
intersection; runtime-only events stay under `ai.<cli>.hooks`.

### Implementation

`lib.ai.mergeWithCollisionCheck` in `lib/ai/ai-common.nix`. The call site is
`lib/ai/app/mkBackendTransform.nix` — **not** `hmTransform.nix` /
`devenvTransform.nix`, which this fragment claimed until 2026-08-10. Those two
are 16-line files that each `import ./mkBackendTransform.nix` with a differing
`backend` key and declare nothing themselves, so the merge (and the per-CLI
baseline option surface, below) is written once and shared:

```nix
mergeCheck = poolName: topPool: cliPool:
  aiCommon.mergeWithCollisionCheck {
    inherit poolName topPool cliPool;
    cliName = appRecord.name;
  };

rulesMerge = mergePool "rules" config.ai.rules cfg.rules;
# ...
collisionAssertions = rulesMerge.assertions ++ ... ;
```

The helper returns `{ merged, assertions }`. The merged shape matches the old
`//` behavior (per-CLI wins) so downstream code keeps resolving until the module
system checks assertions. Assertions aggregate into `config.assertions`
**outside any mkIf guard**, so misconfigurations surface even when the CLI is
toggled off.

### Error message

```
<pool> '<key>' declared in both ai.<pool> and ai.<cli>.<pool> —
collisions across shared ai.* pools are errors. Rename one or
delete the duplicate.
```

### Adding a new shared pool

1. Declare `ai.<pool>` in `lib/ai/sharedOptions.nix` (attrset shape).
2. Declare `ai.<cli>.<pool>` in the mkAiApp baseline
   (`lib/ai/app/mkBackendTransform.nix`, in the `options.ai.${appRecord.name}`
   attrset, gated by `supportsPool`) OR in the per-CLI factory (for CLI-specific
   shape, like kiro's `agents`, whose typed record models Kiro's own v3 agent
   schema rather than the portable one).
3. Add the pool to `supportedPools` for each app record that consumes it.
4. Add `<pool>Merge = mergePool "<pool>" config.ai.<pool> cfg.<pool>;` to the
   transform.
5. Append `<pool>Merge.assertions` to `collisionAssertions`.
6. Set `merged<Pool> = <pool>Merge.merged;`.
7. Add collision and supported/unsupported option tests in
   `checks/module-eval.nix`.

### Pitfall

**Do NOT merge with `//` anywhere in the factory.** That was the old shape — it
silently overrode. If you see a new `//` on a pool merge during code review,
route it through the helper instead. The existing tests cover the collision path
per pool, but a brand-new pool added without the helper will evade detection
until someone happens to configure a collision.

### Debugging

If a collision assertion fires and the user disagrees, inspect which side of the
merge owns the offending key:

```bash
nix eval --impure --expr 'builtins.attrNames \
  (builtins.fromJSON (builtins.readFile ./result/etc/<pool>.json))'
```

Or look at `config.ai.<pool>` / `config.ai.<cli>.<pool>` via
`nix eval .#homeConfigurations.<host>.config.ai.<pool>`.
