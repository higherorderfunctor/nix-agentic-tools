# Buddy Activation-Time Module Design Spec

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Provide a `programs.claude-code.buddy` HM module option that
manages claude-code's buddy companion via activation-time patching,
supporting per-user configuration in multi-user systems and sops-nix
integration for the userId.

**Approach:** Activation script computes a fingerprint of the buddy
options + claude-code store path + userId, compares to a stored
fingerprint at `$XDG_STATE_HOME/claude-code-buddy/fingerprint`, and on
mismatch:

1. Sets up a writable cli.js copy at
   `$XDG_STATE_HOME/claude-code-buddy/lib/cli.js` (rest of the
   `@anthropic-ai/claude-code` lib is symlinked to the store)
2. Reads userId (from text or sops-mounted file)
3. Runs the any-buddy worker (Bun runtime → wyhash)
4. Patches the writable cli.js with the new salt
5. Resets the `companion` field in `~/.claude.json`
6. Writes the new fingerprint

A claude-code wrapper script (installed via the HM module) execs
`bun run $STATE/lib/cli.js` if the user state exists, falling back to
the store cli.js otherwise. This means the binary always works (even
before first activation), and Bun runtime is used so claude-code reads
the salt under wyhash.

---

## Why activation-time, not build-time

The previous build-time approach (`pkgs.claude-code.withBuddy { ... }`)
had three fatal flaws:

1. **No sops support.** `userId` was read at Nix evaluation time, before
   sops decrypts secrets. The salt search baked the UUID into the
   derivation hash, so consumers had to paste plaintext UUIDs.
2. **Multi-user broken.** A NixOS-level `pkgs.claude-code.withBuddy`
   gave all users the same patched binary (same buddy). Buddy is
   user-personal state and can't be system-wide.
3. **Stale companion field.** `~/.claude.json` `companion` is set on
   first hatch and persists across binary swaps. Build-time approach
   couldn't reset it without manual user intervention.

Activation-time fixes all three: sops paths exist when activation runs,
each user has their own state directory, and the activation script can
freely modify `~/.claude.json`.

---

## Consumer API

The canonical option is `programs.claude-code.buddy`. The unified
`ai.claude.buddy` is a convenience that fans out to it (matching the
existing pattern with `ai.skills`, `ai.instructions`, etc.).

### Minimal sops-nix usage

```nix
{config, ...}: {
  ai.claude = {
    enable = true;
    buddy = {
      userId.file = config.sops.secrets."${config.home.username}-claude-uuid".path;
      species = "duck";
    };
  };
}
```

### Inline UUID

```nix
ai.claude.buddy = {
  userId.text = "ebd8b240-9b28-44b1-a4bf-da487d9f111f";
  species = "capybara";
};
```

### Full options

```nix
ai.claude.buddy = {
  userId.file = config.sops.secrets."${username}-claude-uuid".path;
  species = "dragon";
  rarity = "legendary";
  hat = "wizard";
  eyes = "✦";
  shiny = true;
  peak = "WISDOM";
  dump = "CHAOS";
};
```

### Direct (without `ai.*` convenience)

```nix
programs.claude-code = {
  enable = true;
  buddy = {
    userId.file = config.sops.secrets."${username}-claude-uuid".path;
    species = "duck";
  };
};
```

---

## Option Types

### `userId` — discriminated union

Uses `lib.types.attrTag` to enforce exactly one of `text` or `file`:

```nix
userId = mkOption {
  type = types.attrTag {
    text = mkOption {
      type = types.str;
      description = "Literal Claude account UUID string.";
      example = "ebd8b240-9b28-44b1-a4bf-da487d9f111f";
    };
    file = mkOption {
      type = types.path;
      description = ''
        Path to a file containing the Claude account UUID. Read at
        activation time, so sops-nix and agenix paths work.
      '';
      example = literalExpression
        ''config.sops.secrets."''${username}-claude-uuid".path'';
    };
  };
  description = "Claude account UUID source.";
};
```

The module system enforces "exactly one" at type-check time. No
additional assertions needed.

### Other options

| Option    | Type                        | Default    | Description             |
| --------- | --------------------------- | ---------- | ----------------------- |
| `species` | `types.enum`                | (required) | One of 18 species       |
| `rarity`  | `types.enum`                | `"common"` | Rarity tier             |
| `eyes`    | `types.enum`                | `"·"`      | Eye character           |
| `hat`     | `types.enum`                | `"none"`   | Hat accessory           |
| `shiny`   | `types.bool`                | `false`    | Rainbow shimmer variant |
| `peak`    | `types.nullOr (types.enum)` | `null`     | Preferred highest stat  |
| `dump`    | `types.nullOr (types.enum)` | `null`     | Preferred lowest stat   |

### Enum values

**Species** (18): `"axolotl"`, `"blob"`, `"cactus"`, `"capybara"`,
`"cat"`, `"chonk"`, `"dragon"`, `"duck"`, `"ghost"`, `"goose"`,
`"mushroom"`, `"octopus"`, `"owl"`, `"penguin"`, `"rabbit"`,
`"robot"`, `"snail"`, `"turtle"`

**Rarity** (5): `"common"`, `"uncommon"`, `"rare"`, `"epic"`,
`"legendary"`

**Eyes** (6): `"·"`, `"✦"`, `"×"`, `"◉"`, `"@"`, `"°"`

**Hat** (8): `"none"`, `"beanie"`, `"crown"`, `"halo"`,
`"propeller"`, `"tinyduck"`, `"tophat"`, `"wizard"`

**Stats** (5, for peak/dump): `"CHAOS"`, `"DEBUGGING"`,
`"PATIENCE"`, `"SNARK"`, `"WISDOM"`

### Assertions

- `peak != dump` (or both null) — module assertion
- `rarity == "common" → hat == "none"` — module assertion

---

## Module Architecture

### File layout

| File                                       | Responsibility                                              |
| ------------------------------------------ | ----------------------------------------------------------- |
| `lib/buddy-types.nix`                      | Shared `buddySubmodule` type definition                     |
| `modules/claude-code-buddy/default.nix`    | Extends `programs.claude-code` with `buddy` option          |
| `modules/claude-code-buddy/wrapper.nix`    | Wrapper script that execs `bun run cli.js` (state or store) |
| `modules/claude-code-buddy/activation.nix` | Activation script (fingerprint check, salt, patch, reset)   |
| `modules/ai/default.nix`                   | Adds `ai.claude.buddy` fanout to `programs.claude-code`     |

### Wrapper script

Installed via the HM module by overriding `programs.claude-code.package`
with a `symlinkJoin` that replaces `bin/claude` with our wrapper:

```bash
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

USER_LIB="${XDG_STATE_HOME:-$HOME/.local/state}/claude-code-buddy/lib"
STORE_LIB="@CLAUDE_CODE@/lib/node_modules/@anthropic-ai/claude-code"

if [ -f "$USER_LIB/cli.js" ]; then
  CLI="$USER_LIB/cli.js"
else
  CLI="$STORE_LIB/cli.js"
fi

exec @BUN@/bin/bun run "$CLI" "$@"
```

`@CLAUDE_CODE@` and `@BUN@` are substituted at build time. The wrapper
falls back to the store cli.js if the user state doesn't exist yet
(graceful degradation — buddy options are optional, claude still works).

### Activation script

```bash
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-code-buddy"
STORE_LIB="@CLAUDE_CODE@/lib/node_modules/@anthropic-ai/claude-code"
WORKER="@ANY_BUDDY@/src/finder/worker.ts"

# Resolve userId
if [ -n "${BUDDY_USER_ID_FILE:-}" ]; then
  USER_ID=$(cat "$BUDDY_USER_ID_FILE" | tr -d '\n')
else
  USER_ID="$BUDDY_USER_ID_TEXT"
fi

# Compute fingerprint
NEW_FP=$(printf '%s\n' \
  "$STORE_LIB" \
  "$USER_ID" \
  "$BUDDY_SPECIES" \
  "$BUDDY_RARITY" \
  "$BUDDY_EYES" \
  "$BUDDY_HAT" \
  "$BUDDY_SHINY" \
  "$BUDDY_PEAK" \
  "$BUDDY_DUMP" \
  | sha256sum | cut -c1-16)

OLD_FP=$(cat "$STATE_DIR/fingerprint" 2>/dev/null || echo "")
if [ "$NEW_FP" = "$OLD_FP" ]; then
  exit 0  # cached, nothing to do
fi

echo "==> Updating buddy ($BUDDY_SPECIES, $BUDDY_RARITY)"

# Refresh writable cli.js (cleanup old state, fresh symlink tree)
rm -rf "$STATE_DIR/lib"
mkdir -p "$STATE_DIR/lib"
cp -rs "$STORE_LIB"/* "$STATE_DIR/lib/"
chmod -R u+w "$STATE_DIR/lib"
# Replace cli.js symlink with a real writable copy
rm "$STATE_DIR/lib/cli.js"
cp -L "$STORE_LIB/cli.js" "$STATE_DIR/lib/cli.js"
chmod u+w "$STATE_DIR/lib/cli.js"

# Run salt search (Bun runtime, no --fnv1a since we're using Bun runtime)
SALT=$(@BUN@/bin/bun "$WORKER" \
  "$USER_ID" \
  "$BUDDY_SPECIES" \
  "$BUDDY_RARITY" \
  "$BUDDY_EYES" \
  "$BUDDY_HAT" \
  "$BUDDY_SHINY" \
  "$BUDDY_PEAK" \
  "$BUDDY_DUMP" \
  | @JQ@/bin/jq -r '.salt')

if [[ ! "$SALT" =~ ^[a-zA-Z0-9_-]{15}$ ]]; then
  echo "ERROR: invalid salt format: '$SALT'" >&2
  exit 1
fi

# Patch cli.js
@PYTHON3@/bin/python3 -c "
import sys
path = '$STATE_DIR/lib/cli.js'
data = open(path, 'rb').read()
old = b'friend-2026-401'
new = b'$SALT'
if old not in data:
    sys.exit('ERROR: salt marker not found in cli.js')
open(path, 'wb').write(data.replace(old, new))
"

# Reset companion field in claude.json (ignore if file doesn't exist)
if [ -f "$HOME/.claude.json" ]; then
  tmp=$(mktemp)
  @JQ@/bin/jq 'del(.companion)' "$HOME/.claude.json" > "$tmp"
  mv "$tmp" "$HOME/.claude.json"
fi

# Save fingerprint
mkdir -p "$STATE_DIR"
echo -n "$NEW_FP" > "$STATE_DIR/fingerprint"

echo "==> Buddy updated. Next claude run will hatch a new $BUDDY_SPECIES."
```

### Module config wiring

```nix
config = lib.mkIf (cfg != null) {
  assertions = [
    { assertion = cfg.peak != cfg.dump || cfg.peak == null;
      message = "programs.claude-code.buddy: peak and dump must differ"; }
    { assertion = cfg.rarity == "common" -> cfg.hat == "none";
      message = "programs.claude-code.buddy: common rarity forces hat = none"; }
  ];

  programs.claude-code.package = lib.mkForce (
    pkgs.symlinkJoin {
      name = "claude-code-buddy-wrapper";
      paths = [pkgs.claude-code];
      postBuild = ''
        rm $out/bin/claude
        cat > $out/bin/claude <<EOF
        #!/usr/bin/env bash
        ...
        EOF
        chmod +x $out/bin/claude
      '';
    }
  );

  home.activation.claudeBuddy = lib.hm.dag.entryAfter ["writeBoundary"] ''
    export BUDDY_USER_ID_FILE="${cfg.userId.file or ""}"
    export BUDDY_USER_ID_TEXT="${cfg.userId.text or ""}"
    export BUDDY_SPECIES="${cfg.species}"
    export BUDDY_RARITY="${cfg.rarity}"
    export BUDDY_EYES="${cfg.eyes}"
    export BUDDY_HAT="${cfg.hat}"
    export BUDDY_SHINY="${if cfg.shiny then "true" else ""}"
    export BUDDY_PEAK="${cfg.peak or ""}"
    export BUDDY_DUMP="${cfg.dump or ""}"
    ${activationScript}
  '';
};
```

### `ai.claude.buddy` fanout

```nix
# In modules/ai/default.nix
options.ai.claude.buddy = mkOption {
  type = types.nullOr buddySubmodule;
  default = null;
  description = "Buddy companion config (fans out to programs.claude-code.buddy).";
};

config = mkIf cfg.enable {
  programs.claude-code.buddy = mkIf (cfg.claude.buddy != null) cfg.claude.buddy;
};
```

---

## Caching Behavior

The fingerprint check covers all relevant invalidation cases:

| Trigger                               | Fingerprint changes? | Action                            |
| ------------------------------------- | -------------------- | --------------------------------- |
| First setup                           | (no file exists)     | Run salt search, patch, reset     |
| Buddy options unchanged               | No                   | Skip (cached)                     |
| Buddy option changed                  | Yes                  | Re-run, re-patch, reset companion |
| claude-code version upgrade           | Yes (store path)     | Re-run, re-patch, reset companion |
| sops-decrypted UUID file changed      | Yes                  | Re-run, re-patch, reset companion |
| User manually edited cli.js or json   | No (we don't detect) | No action                         |
| Migration from build-time `withBuddy` | (no fingerprint)     | Run, reset companion              |

The companion field is always reset whenever the activation script runs
(i.e., on any fingerprint mismatch). This guarantees that whenever the
salt changes, the cached buddy state in `~/.claude.json` is invalidated.

---

## Bun Runtime

The wrapper uses `bun run cli.js` instead of `node cli.js`. This:

- Activates wyhash for the buddy hash (via `typeof Bun !== 'undefined'`)
- Means the salt search worker can drop `--fnv1a` (defaults to wyhash)
- Adds Bun (~95 MB) to the runtime closure

This is the "Option A wrapper" approach from the claude-code-nix research.
Startup overhead is negligible (~50 ms vs Node, dominated by MCP probes
in real workloads). Compile-time bun (`bun build --compile`) was
evaluated and rejected — it doubles binary size, slows startup slightly,
and breaks the writable-cli.js patching pattern.

---

## What Gets Removed

### Files deleted

- `packages/ai-clis/with-buddy.nix` (build-time patching derivation)
- `packages/ai-clis/buddy-salt.nix` (build-time salt search derivation)

### Files modified

- `packages/ai-clis/claude-code.nix`: remove `withBuddyFn` parameter and
  `passthru.withBuddy`
- `packages/ai-clis/default.nix`: remove `mkBuddySalt`/`withBuddyFn` wiring
- `modules/ai/default.nix`: replace existing buddy submodule with the
  new fanout pattern (just sets `programs.claude-code.buddy`)
- `modules/devenv/ai.nix`: remove buddy entirely (per-user, not per-project)
- `dev/docs/guides/buddy-customization.md`: rewrite for new architecture
- `flake.nix`: register the new module under `homeManagerModules`

### Files unchanged

- `packages/ai-clis/any-buddy.nix` (worker source still needed)
- `nvfetcher.toml` `[any-buddy]` entry
- `checks/module-eval.nix` (test will need a small update for new option shape)

---

## Verification

After implementing:

1. `nix flake check --no-build` passes
2. Module evaluation test (`ai-buddy-eval`) passes with new option shape
3. Standalone activation script test:
   - Set up env vars manually
   - Run script
   - Verify cli.js patched, fingerprint written, companion field cleared
4. Re-run with same options: should be a no-op (fingerprint cached)
5. Change species and re-run: should re-patch and reset companion

---

## Open Questions

1. **Module location:** new `modules/claude-code-buddy/` directory or
   inline in existing `modules/ai/` files? Separate dir is cleaner and
   matches the convention of one feature per module dir, but adds a
   file. Going with separate dir.

2. **Fallback when buddy disabled:** if user removes buddy config, the
   activation script doesn't run, leaving the writable cli.js in
   `$STATE/lib`. The wrapper still execs that stale patched copy.
   Solution: when buddy is null, the package override doesn't apply
   (mkForce only runs when buddy != null), so user gets the unwrapped
   `pkgs.claude-code`. The state dir is leftover but harmless. Worth a
   cleanup hook? Probably not — `rm -rf $STATE_DIR` is a one-liner.

3. **Bun version:** nixpkgs `bun` is fine (1.3.11 tested). User's
   newer-bun overlay isn't needed.
