# Buddy Customization

Customize your Claude Code terminal companion (buddy) via Nix.
The buddy is patched into the binary at build time — no runtime
modification needed.

## Quick Start

```nix
# In your home-manager config:
ai.claude = {
  enable = true;
  buddy = {
    userId = "your-account-uuid-here";
    species = "dragon";
    rarity = "legendary";
    hat = "wizard";
    eyes = "✦";
  };
};
```

Your account UUID is in `~/.claude.json` under
`oauthAccount.accountUuid`.

> **Note on secrets:** The UUID is read at **build time** by Nix
> evaluation, before any runtime secret manager has mounted its
> secrets. sops-nix and agenix decrypt to paths like
> `/run/user/<uid>/secrets/` during activation — those paths
> don't exist when Nix evaluates your config, so they cannot
> provide the userId.
>
> **The UUID is not cryptographically secret.** It's a stable
> identifier Anthropic uses to associate data with your account
> (closer to an email address than a password). It can't
> authenticate as you, make API calls, or access conversations.
> The actual auth secrets are the OAuth tokens in `~/.claude.json`
> (`sessionToken`, `refreshToken`) — those should still be
> protected, but the UUID does not need the same treatment.
>
> **Recommended:** Paste the UUID directly into your config as a
> literal string. It ends up in the nix store (in the derivation
> hash), but that's the same machine that already has your auth
> tokens, so the threat model doesn't change.
>
> If you want to keep the UUID out of your config repo without an
> activation script, read from a plaintext file outside the repo
> at eval time:
>
> ```nix
> userId = lib.removeSuffix "\n"
>   (builtins.readFile /home/you/.config/nix-secrets/claude-uuid);
> ```
>
> The path must be a Nix path literal (no quotes, no `~`) and the
> file must exist before `home-manager switch` runs.

## Direct Package Usage

Without the module system:

```nix
pkgs.claude-code.withBuddy {
  userId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx";
  species = "capybara";
  rarity = "rare";
  shiny = true;
  peak = "WISDOM";
  dump = "CHAOS";
}
```

## Available Options

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

## Build Time

The salt search runs once and is cached. It only re-runs when
your buddy options change — not on claude-code version updates.

| Target                          | Time    |
| ------------------------------- | ------- |
| Common + species                | instant |
| Rare + species + hat            | <1s     |
| Legendary + species             | ~1s     |
| Legendary + shiny               | ~30s    |
| Legendary + shiny + peak + dump | minutes |

## How It Works

Under the hood, `withBuddy` creates two Nix derivations:

1. **Salt search** — brute-forces a 15-character salt string
   that, when hashed with your account UUID, produces the
   desired buddy traits. Uses any-buddy's worker script via Bun.
2. **Binary patching** — replaces the default salt in the
   claude-code binary with your computed salt. Uses python3 for
   binary-safe replacement.

The salt search derivation depends only on your buddy options
and UUID. The patching derivation depends on the claude-code
package. This means version updates only trigger the cheap
patching step, not the expensive salt search.
