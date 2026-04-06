# withBuddy Design Spec

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a `withBuddy` passthru function to the claude-code package
that binary-patches the buddy companion salt at build time, with all
options type-checked via Nix enum literals.

**Approach:** Package any-buddy from npm, invoke its worker script
directly via Bun at build time for salt search, then do a trivial
byte replacement on the claude-code binary. Two-derivation split
separates the expensive salt search from the cheap patching so
claude-code version bumps don't re-trigger the search.

---

## Architecture

### Two-Derivation Split

```
buddy-salt derivation                 withBuddy derivation
(expensive, cached forever)           (cheap, runs on claude-code update)

Inputs:                               Inputs:
  - userId                              - claude-code package
  - species, rarity, eyes,             - salt (from buddy-salt)
    hat, shiny, peak, dump
                                      Steps:
Steps:                                  1. Copy claude-code to $out
  1. Run any-buddy worker               2. Replace "friend-2026-401"
     via Bun                                (15 bytes, 3 occurrences
  2. Write salt to $out                     in ELF/Mach-O, 1 in .js)
                                         3. On darwin: codesign
```

The consumer-facing `withBuddy` function creates both derivations
internally. The split is an implementation detail — consumers pass
options once and get a patched package back.

### Consumer API

```nix
# Direct passthru usage
pkgs.claude-code.withBuddy {
  userId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx";
  species = "dragon";
  rarity = "legendary";
  eyes = "✦";
  hat = "wizard";
  shiny = true;
  peak = "CHAOS";
  dump = "PATIENCE";
}

# Via HM module
programs.ai.claude = {
  enable = true;
  buddy = {
    userId = config.sops.secrets.claude-uuid.path;
    species = "dragon";
    rarity = "legendary";
  };
};
```

---

## Option Types

All options use enum literals for closed domains. Free-form strings
only where the domain is genuinely open (userId).

### Required Options

| Option    | Type         | Description                                                                                                           |
| --------- | ------------ | --------------------------------------------------------------------------------------------------------------------- |
| `userId`  | `types.str`  | Claude account UUID (`oauthAccount.accountUuid` from `~/.claude.json`). Consumer manages secrecy (sops, agenix, etc.) |
| `species` | `types.enum` | One of 18 species (see below)                                                                                         |

### Optional Options

| Option   | Type                        | Default    | Description             |
| -------- | --------------------------- | ---------- | ----------------------- |
| `rarity` | `types.enum`                | `"common"` | Rarity tier             |
| `eyes`   | `types.enum`                | `"·"`      | Eye character           |
| `hat`    | `types.enum`                | `"none"`   | Hat accessory           |
| `shiny`  | `types.bool`                | `false`    | Rainbow shimmer variant |
| `peak`   | `types.nullOr (types.enum)` | `null`     | Preferred highest stat  |
| `dump`   | `types.nullOr (types.enum)` | `null`     | Preferred lowest stat   |

### Enum Values

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

```nix
assertions = [
  {
    assertion = cfg.peak != cfg.dump || cfg.peak == null;
    message = "withBuddy: peak and dump stats must differ";
  }
  {
    assertion = cfg.rarity == "common" -> cfg.hat == "none";
    message = "withBuddy: common rarity forces hat = \"none\"";
  }
];
```

---

## Package Structure

### New Files

| File                              | Purpose                                        |
| --------------------------------- | ---------------------------------------------- |
| `packages/ai-clis/any-buddy.nix`  | Package any-buddy from npm via nvfetcher       |
| `packages/ai-clis/buddy-salt.nix` | `mkBuddySalt` function: salt search derivation |
| `packages/ai-clis/with-buddy.nix` | `withBuddy` function: patching derivation      |

### Modified Files

| File                               | Change                                             |
| ---------------------------------- | -------------------------------------------------- |
| `packages/ai-clis/claude-code.nix` | Add `passthru.withBuddy` wired to `with-buddy.nix` |
| `packages/ai-clis/default.nix`     | Register any-buddy in overlay                      |
| `flake.nix`                        | Expose any-buddy in packages                       |
| `nvfetcher.toml`                   | Add any-buddy source tracking                      |
| `packages/ai-clis/hashes.json`     | Add any-buddy npmDepsHash                          |
| `packages/ai-clis/sources.nix`     | Merge any-buddy source entry                       |
| `modules/ai/default.nix`           | Add `buddy` option under `ai.claude`               |
| `modules/devenv/ai.nix`            | Add `buddy` option (config parity)                 |

### Documentation Updates

| File                  | Change                            |
| --------------------- | --------------------------------- |
| Doc site Claude page  | New "Buddy Customization" section |
| README feature matrix | Mention buddy support             |
| Dev fragments         | any-buddy packaging pattern       |

---

## Build Mechanism

### buddy-salt derivation (`mkBuddySalt`)

```nix
mkBuddySalt = {
  userId, species, rarity, eyes, hat, shiny, peak, dump
}: pkgs.runCommand "buddy-salt" {
  nativeBuildInputs = [ pkgs.bun ];
  # All options as env vars for the build script
} ''
  salt=$(bun ${any-buddy}/lib/any-buddy/src/finder/worker.ts \
    "${userId}" "${species}" "${rarity}" "${eyes}" "${hat}" \
    "${if shiny then "true" else ""}" \
    "${if peak != null then peak else ""}" \
    "${if dump != null then dump else ""}" \
    | ${pkgs.jq}/bin/jq -r '.salt')
  echo -n "$salt" > $out
'';
```

**Cache behavior:** Inputs are `userId + buddy options`. Claude-code
version bumps do not invalidate this derivation.

**Build time by target:**

| Target                          | ~Attempts    | Time    |
| ------------------------------- | ------------ | ------- |
| Common + species + eye          | ~180         | instant |
| Rare + species + eye + hat      | ~8,600       | <1s     |
| Legendary + species             | ~86,000      | ~1s     |
| Legendary + shiny               | ~8,600,000   | ~30s    |
| Legendary + shiny + peak + dump | ~170,000,000 | minutes |

### withBuddy patching derivation

```nix
withBuddy = opts: let
  salt = builtins.readFile (mkBuddySalt opts);
  original = "friend-2026-401";
in pkgs.runCommand "claude-code-buddy" {
  nativeBuildInputs =
    lib.optional pkgs.stdenv.hostPlatform.isDarwin pkgs.sigtool;
} ''
  cp -r ${claude-code} $out
  chmod -R u+w $out

  # Binary-safe 15-byte replacement (ASCII-only, same length)
  # python3 for reliable binary read/write — sd/sed are
  # text-oriented and may corrupt ELF null bytes
  for f in $(find $out -type f \( -name "claude-code" -o -name "cli.js" \)); do
    ${pkgs.python3}/bin/python3 -c "
  import sys
  data = open(sys.argv[1], 'rb').read()
  patched = data.replace(b'${original}', b'${salt}')
  assert patched != data, 'salt not found in binary'
  open(sys.argv[1], 'wb').write(patched)
    " "$f"
  done

  # macOS ad-hoc re-signing
  ${lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
    codesign --force --sign - $out/bin/claude-code
  ''}
'';
```

### Worker Invocation Details

The any-buddy worker (`src/finder/worker.ts`) is a standalone script:

- **Invocation:** positional args: `userId species rarity eye hat [shiny] [peak] [dump]`
- **Hash function:** Uses `Bun.hash()` (wyhash) — Bun is required
- **Output:** JSON to stdout: `{"salt": "<15-char>", "attempts": N, "elapsed": N}`
- **Exit:** Code 0 on success
- **Salt format:** Exactly 15 characters from `[a-zA-Z0-9_-]`
- **Original salt:** `"friend-2026-401"` (also 15 chars)
- **Occurrences in binary:** 3 in compiled ELF/Mach-O, 1 in JS bundle

### Platform Concerns

- **Linux:** No special handling beyond file permissions
- **macOS:** Must ad-hoc re-sign after patching (`codesign --force --sign -`)
- **Build sandbox:** Worker needs no network access, only CPU

---

## HM Module Integration

```nix
# modules/ai/default.nix — additions
buddy = mkOption {
  type = types.nullOr (types.submodule {
    options = {
      userId = mkOption { type = types.str; };
      species = mkOption {
        type = types.enum [
          "axolotl" "blob" "cactus" "capybara" "cat" "chonk"
          "dragon" "duck" "ghost" "goose" "mushroom" "octopus"
          "owl" "penguin" "rabbit" "robot" "snail" "turtle"
        ];
      };
      rarity = mkOption {
        type = types.enum [
          "common" "uncommon" "rare" "epic" "legendary"
        ];
        default = "common";
      };
      eyes = mkOption {
        type = types.enum [ "·" "✦" "×" "◉" "@" "°" ];
        default = "·";
      };
      hat = mkOption {
        type = types.enum [
          "none" "beanie" "crown" "halo"
          "propeller" "tinyduck" "tophat" "wizard"
        ];
        default = "none";
      };
      shiny = mkOption {
        type = types.bool;
        default = false;
      };
      peak = mkOption {
        type = types.nullOr (types.enum [
          "CHAOS" "DEBUGGING" "PATIENCE" "SNARK" "WISDOM"
        ]);
        default = null;
      };
      dump = mkOption {
        type = types.nullOr (types.enum [
          "CHAOS" "DEBUGGING" "PATIENCE" "SNARK" "WISDOM"
        ]);
        default = null;
      };
    };
  });
  default = null;
  description = ''
    Buddy companion customization. When set, the claude-code
    package is patched at build time with a salt that produces
    the specified companion for your account.

    Build time depends on rarity: common is instant, legendary
    shiny with specific stats may take minutes. The salt is
    cached — only recomputed when buddy options change, not on
    claude-code version bumps.
  '';
};
```

**Module config wiring:**

```nix
config = mkIf cfg.enable {
  assertions = lib.optionals (cfg.buddy != null) [
    {
      assertion = cfg.buddy.peak != cfg.buddy.dump
        || cfg.buddy.peak == null;
      message = "ai.claude.buddy: peak and dump must differ";
    }
    {
      assertion = cfg.buddy.rarity == "common"
        -> cfg.buddy.hat == "none";
      message = "ai.claude.buddy: common rarity forces hat = none";
    }
  ];

  # Override package when buddy is configured
  ai.claude.package = mkIf (cfg.buddy != null)
    (cfg.package.withBuddy cfg.buddy);
};
```

---

## any-buddy Package

### nvfetcher Entry

```toml
[any-buddy]
src.git = "https://github.com/cpaczek/any-buddy.git"
src.branch = "main"
fetch.git = "https://github.com/cpaczek/any-buddy.git"
```

### Derivation Pattern

Package as a standard npm project. We only need the source tree
available at build time for the worker script — we do not need to
build or install the full CLI.

However, the worker imports from other source files (`generation/hash`,
`generation/rng`, `generation/roll`, `constants`), so the full source
tree must be present. Packaging as `buildNpmPackage` ensures
dependencies are resolved and the source is intact.

Alternative: `fetchFromGitHub` + just make the source tree available
without a full npm install, since Bun can resolve imports from source.
This avoids needing npmDepsHash. Test whether `bun run worker.ts`
works from the raw source tree without `npm install`.

---

## Scope Exclusions

- **name/personality:** These are the "soul layer" — LLM-generated
  at first hatch, stored in `~/.claude-code-any-buddy.json`. Not in
  the binary, not relevant to Nix packaging
- **Auto-patch hook:** Not needed — Nix rebuilds handle updates
- **withPlugins:** Separate feature for the real plugin system.
  Different mechanism (symlinks, not binary patching)
- **devenv buddy option:** Add for config parity but lower priority
  than HM module

---

## Verification

After building `claude-code.withBuddy { ... }`:

1. Binary contains the new salt (not `friend-2026-401`)
2. Salt appears the expected number of times (3 in ELF, 1 in JS)
3. `claude-code --version` still works (binary not corrupted)
4. On macOS: binary passes Gatekeeper (`codesign -v`)
5. Running `/buddy` in the patched binary shows the expected species

---

## Open Questions

1. **Worker without npm install:** Can `bun src/finder/worker.ts`
   run from a raw git checkout without `npm install`? If yes, we
   can skip `buildNpmPackage` and just use `fetchFromGitHub`. If
   not, we need full npm deps resolution.

2. **Parallelism in salt search:** The worker is single-process.
   For extreme targets (legendary shiny + peak + dump), spawning
   multiple workers in the build script would cut time linearly.
   Worth the complexity? Probably not for v1.

3. **Salt stability across any-buddy versions:** If upstream changes
   the salt format (currently 15 chars, `[a-zA-Z0-9_-]`), the
   patching would break. Pin any-buddy version via nvfetcher to
   control updates.

4. **Upstream salt change by Anthropic:** If Anthropic changes
   `friend-2026-401` in a future claude-code release, both
   any-buddy and our patching break. Low risk — the salt is
   embedded in the compiled binary and any-buddy tracks it.
