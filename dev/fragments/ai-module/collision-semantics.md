## ai.\* Collision Semantics

> **Last verified:** 2026-04-21 (commit pending — refactor of
> ai-factory-collision plan §3.2). If you add a new shared pool
> to `ai.*` or change how pools are merged across the L2↔L3
> boundary and this fragment isn't updated in the same commit,
> stop and fix it.

### Rule

Duplicate keys across any shared `ai.*` pool are a **failure
condition**, not a silent override. The factory used to merge
the top-level pool with the per-CLI pool via `config.ai.<pool>
// cfg.<pool>`, letting a later per-CLI contribution silently
overwrite a same-name top-level entry. User directive: "mixing
and collision should be a failure. we don't merge over keys."

### Covered pools

Applies to every attrset-shaped shared pool in `ai.*`:

- `ai.rules` / `ai.<cli>.rules`
- `ai.skills` / `ai.<cli>.skills`
- `ai.mcpServers` / `ai.<cli>.mcpServers`
- `ai.lspServers` / `ai.<cli>.lspServers`
- `ai.environmentVariables` / `ai.<cli>.environmentVariables`
- `ai.agents` / `ai.<cli>.agents`

`ai.instructions` is a list, not an attrset, so list concat
stays as-is. `ai.context` is single-valued.

### Implementation

`lib.ai.mergeWithCollisionCheck` in `lib/ai/ai-common.nix`. Call
site in `lib/ai/app/hmTransform.nix` and `devenvTransform.nix`:

```nix
mergeCheck = poolName: topPool: cliPool:
  aiCommon.mergeWithCollisionCheck {
    inherit poolName topPool cliPool;
    cliName = appRecord.name;
  };

rulesMerge = mergeCheck "rules" config.ai.rules cfg.rules;
# ...
collisionAssertions = rulesMerge.assertions ++ ... ;
```

The helper returns `{ merged, assertions }`. The merged shape
matches the old `//` behavior (per-CLI wins) so downstream
code keeps resolving until the module system checks
assertions. Assertions aggregate into `config.assertions`
**outside any mkIf guard**, so misconfigurations surface even
when the CLI is toggled off.

### Error message

```
<pool> '<key>' declared in both ai.<pool> and ai.<cli>.<pool> —
collisions across shared ai.* pools are errors. Rename one or
delete the duplicate.
```

### Adding a new shared pool

1. Declare `ai.<pool>` in `lib/ai/sharedOptions.nix` (attrset
   shape).
2. Declare `ai.<cli>.<pool>` in the mkAiApp baseline
   (`lib/ai/app/hmTransform.nix` + `devenvTransform.nix`) OR in
   the per-CLI factory (for CLI-specific shape, like kiro's
   JSON `agents`).
3. Add `<pool>Merge = mergeCheck "<pool>" config.ai.<pool>
cfg.<pool>;` to the transform.
4. Append `<pool>Merge.assertions` to `collisionAssertions`.
5. Set `merged<Pool> = <pool>Merge.merged;`.
6. Add a collision test in `checks/module-eval.nix`.

### Pitfall

**Do NOT merge with `//` anywhere in the factory.** That was
the old shape — it silently overrode. If you see a new `//`
on a pool merge during code review, route it through the
helper instead. The existing tests cover the collision path
per pool, but a brand-new pool added without the helper will
evade detection until someone happens to configure a
collision.

### Debugging

If a collision assertion fires and the user disagrees, inspect
which side of the merge owns the offending key:

```bash
nix eval --impure --expr 'builtins.attrNames \
  (builtins.fromJSON (builtins.readFile ./result/etc/<pool>.json))'
```

Or look at `config.ai.<pool>` / `config.ai.<cli>.<pool>` via
`nix eval .#homeConfigurations.<host>.config.ai.<pool>`.
