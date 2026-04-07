# Buddy Customization

Customize your Claude Code terminal companion (buddy) via Nix.
The buddy is patched at home-manager **activation time**, not build
time, so it works with sops-nix secrets and gives each user their
own buddy in multi-user systems.

## Quick Start

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

The `userId.file` reads your account UUID from a sops-nix (or
agenix, or any plaintext file) at activation time. Your account
UUID is in `~/.claude.json` under `oauthAccount.accountUuid`.

The UUID is **not** a real secret — it can't authenticate or make
API calls. It's a stable identifier. But if you prefer to keep it
out of your config repo, sops works.

## Inline UUID

If you don't want sops, paste the UUID directly:

```nix
ai.claude.buddy = {
  userId.text = "ebd8b240-9b28-44b1-a4bf-da487d9f111f";
  species = "capybara";
};
```

## Direct (without `ai.*` convenience)

The canonical option is `programs.claude-code.buddy`. The `ai.claude.buddy`
above is just a fanout convenience that sets it for you.

```nix
programs.claude-code = {
  enable = true;
  buddy = {
    userId.file = config.sops.secrets."${config.home.username}-claude-uuid".path;
    species = "duck";
  };
};
```

## Full Options

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

### Species (18)

axolotl, blob, cactus, capybara, cat, chonk, dragon, duck,
ghost, goose, mushroom, octopus, owl, penguin, rabbit, robot,
snail, turtle

### Rarity

common (default), uncommon, rare, epic, legendary

### Eyes

`·` (default), `✦`, `×`, `◉`, `@`, `°`

### Hat

none (default), beanie, crown, halo, propeller, tinyduck,
tophat, wizard

Note: common rarity forces `hat = "none"`.

### Stats (peak/dump)

CHAOS, DEBUGGING, PATIENCE, SNARK, WISDOM

Both are optional. When set, the salt search constrains which
stat is highest (peak) and lowest (dump). They must differ.

## Build/Activation Time

The salt search runs once during home-manager activation and is
cached by a fingerprint of your buddy options + claude-code
version + userId. It only re-runs when something changes.

| Target                          | Time    |
| ------------------------------- | ------- |
| Common + species                | instant |
| Rare + species + hat            | <1s     |
| Legendary + species             | ~1s     |
| Legendary + shiny               | ~30s    |
| Legendary + shiny + peak + dump | minutes |

## How It Works

The package and the user state are layered:

1. **Package layer** (`pkgs.claude-code`): Our overlay wraps
   nixpkgs' claude-code with a Bun-runtime wrapper at
   `bin/claude`. The wrapper checks for a writable `cli.js` at
   `$XDG_STATE_HOME/claude-code-buddy/lib/cli.js`. If it exists,
   the wrapper execs it. Otherwise it falls back to the store
   `cli.js`. The wrapper is harmless when no buddy is configured —
   you just get unmodified claude-code under Bun.

2. **State layer** (HM activation script): When `buddy` is set,
   the activation script:
   - Computes a fingerprint of `(claude-code store path, userId,
buddy options)`
   - Compares to `$XDG_STATE_HOME/claude-code-buddy/fingerprint`
   - If different: copies the cli.js (and symlinks the rest of
     the lib) into `$XDG_STATE_HOME/claude-code-buddy/lib/`,
     runs the any-buddy worker via Bun, patches the writable
     cli.js, resets the `companion` field in `~/.claude.json`,
     and writes the new fingerprint
   - If same: exits cleanly (cached)

The companion field reset ensures the next `claude` invocation
re-hatches with the new buddy traits. Without it, claude-code
would keep showing the cached buddy from the first hatch.

## Why Activation-Time Instead of Build-Time

Earlier versions of this feature (`pkgs.claude-code.withBuddy { ... }`)
patched the binary at build time. Three problems:

1. **No sops support.** The userId was read at Nix evaluation,
   before sops decrypts secrets.
2. **Multi-user broken.** A NixOS-level install gave all users
   the same patched binary, since the salt was baked into the
   nix store path.
3. **Stale companion field.** The buddy state in `~/.claude.json`
   couldn't be reset by a build-time approach.

Activation-time fixes all three. The trade-off is a small amount
of state management in `$XDG_STATE_HOME/claude-code-buddy/`, which
is a fair price.

## Why Bun

claude-code runs under whichever JS runtime executes its `cli.js`.
Our overlay wrapper invokes `bun run cli.js` instead of `node`,
which activates the wyhash code path inside claude-code's buddy
hash function. The any-buddy worker also defaults to wyhash, so
the salts the worker computes match what claude-code reads at
runtime.

If we ran under Node, claude-code would use fnv1a internally, and
we'd need to pass `--fnv1a` to the worker to match. We chose Bun
for the cleaner alignment.

Startup overhead is negligible (~50 ms vs Node), dominated by MCP
probes in real workloads.
