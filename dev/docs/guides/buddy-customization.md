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
> evaluation. Runtime secret managers (sops-nix, agenix) cannot
> provide it — their secret paths don't exist during evaluation,
> and `builtins.readFile` on a sops path would either fail or
> import the secret into the nix store anyway.
>
> **Practical patterns:**
>
> 1. **Inline literal** — paste the UUID directly into your
>    config. The UUID ends up in the derivation hash and the
>    patched binary either way; treating it as a secret in your
>    config repo is the only meaningful protection.
> 2. **Plaintext file outside the repo** — read with
>    `builtins.readFile` from a path Nix can access at eval time:
>
>    ```nix
>    userId = lib.removeSuffix "\n"
>      (builtins.readFile /home/you/.config/nix-secrets/claude-uuid);
>    ```
>
>    The file must exist when `home-manager switch` runs. If you
>    use sops to manage it, decrypt to this path **before**
>    activation (e.g., via a separate script or systemd unit
>    that runs before `home-manager-<user>.service`).
>
> The UUID is not cryptographically secret — it's a stable
> identifier Anthropic uses to derive your buddy. The patched
> binary contains only the computed salt, not the UUID itself.

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
