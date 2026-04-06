# withBuddy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `withBuddy` passthru function to the claude-code
package that binary-patches the buddy companion salt at build time,
with all options type-checked via Nix enum literals.

**Architecture:** Two-derivation split — an expensive `buddy-salt`
derivation (cached until buddy options change, independent of
claude-code version) and a cheap patching derivation (runs on every
claude-code update, just byte replacement). any-buddy's worker script
is invoked via Bun at build time for the salt search. The HM and
devenv modules expose a `buddy` option under `ai.claude`.

**Tech Stack:** Nix (alejandra format), any-buddy (npm), Bun
(nativeBuildInput for wyhash), python3 (binary-safe byte replacement)

**Spec:** `docs/superpowers/specs/2026-04-06-with-buddy-design.md`

---

## File Structure

### New Files

| File                                     | Responsibility                                       |
| ---------------------------------------- | ---------------------------------------------------- |
| `packages/ai-clis/any-buddy.nix`         | Package any-buddy source tree from git via nvfetcher |
| `packages/ai-clis/buddy-salt.nix`        | `mkBuddySalt` function: salt search derivation       |
| `packages/ai-clis/with-buddy.nix`        | `withBuddy` function: binary patching derivation     |
| `dev/docs/guides/buddy-customization.md` | Consumer documentation for buddy feature             |

### Modified Files

| File                               | Change                                      |
| ---------------------------------- | ------------------------------------------- |
| `nvfetcher.toml`                   | Add any-buddy git source entry              |
| `packages/ai-clis/sources.nix`     | Merge any-buddy into sources attrset        |
| `packages/ai-clis/default.nix`     | Register any-buddy, wire withBuddy passthru |
| `packages/ai-clis/claude-code.nix` | Add passthru.withBuddy                      |
| `flake.nix`                        | Expose any-buddy in packages                |
| `modules/ai/default.nix`           | Add buddy option under ai.claude            |
| `modules/devenv/ai.nix`            | Add buddy option (config parity)            |
| `checks/module-eval.nix`           | Add buddy module evaluation tests           |
| `dev/docs/SUMMARY.md`              | Add Buddy Customization guide entry         |

---

### Task 1: Add any-buddy to nvfetcher

**Files:**

- Modify: `nvfetcher.toml`

- [ ] **Step 1: Add any-buddy entry to nvfetcher.toml**

Add under the `# ── AI CLIs ──` section, alphabetically before
`claude-code`:

```toml
[any-buddy]
src.github = "cpaczek/any-buddy"
fetch.github = "cpaczek/any-buddy"
```

- [ ] **Step 2: Run nvfetcher to generate source metadata**

Run: `nvfetcher`

Expected: `.nvfetcher/generated.nix` updated with an `any-buddy` entry
containing `version`, `src` (fetchFromGitHub).

- [ ] **Step 3: Verify generated entry**

Run: `nix eval -f .nvfetcher/generated.nix --apply 'f: (f {fetchgit = _: _; fetchurl = _: _; fetchFromGitHub = _: _; dockerTools = {};}).any-buddy.version' --raw`

Expected: Prints a version string or commit hash.

- [ ] **Step 4: Format and commit**

```bash
treefmt nvfetcher.toml
git add nvfetcher.toml .nvfetcher/generated.nix
git commit -m "chore(ai-clis): add any-buddy to nvfetcher tracking"
```

---

### Task 2: Package any-buddy source

**Files:**

- Create: `packages/ai-clis/any-buddy.nix`
- Modify: `packages/ai-clis/sources.nix`
- Modify: `packages/ai-clis/default.nix`
- Modify: `flake.nix`

We only need any-buddy's source tree available for the worker script
invocation — not a fully built npm package. However, the worker
imports from sibling modules (`generation/hash`, `generation/rng`,
`generation/roll`, `constants`), and Bun resolves TypeScript imports
at runtime. Test whether `bun src/finder/worker.ts` works from a raw
git checkout. If it does, use `fetchFromGitHub` directly (no
`buildNpmPackage`). If it needs dependencies, use `buildNpmPackage`.

- [ ] **Step 1: Test if worker runs from raw source**

Run (in a temp directory):

```bash
nix-shell -p bun git --run '
  dir=$(mktemp -d)
  git clone --depth 1 https://github.com/cpaczek/any-buddy.git "$dir"
  echo "test-user duck common · none" | xargs bun "$dir/src/finder/worker.ts"
'
```

Expected: Either JSON output `{"salt": "...", "attempts": N, ...}` (raw
source works) or an import error (need npm deps). Record which path.

- [ ] **Step 2: Create any-buddy.nix**

If raw source works (likely — Bun resolves TS natively, the worker
only uses built-in modules + sibling imports):

```nix
# any-buddy — source-only package for buddy salt search worker.
# Not a built CLI — we invoke src/finder/worker.ts directly via Bun.
{
  final,
  nv,
}:
final.stdenvNoCC.mkDerivation {
  pname = "any-buddy-source";
  inherit (nv) version src;

  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r . $out/
    runHook postInstall
  '';

  meta = {
    description = "Source tree for any-buddy salt search worker";
    homepage = "https://github.com/cpaczek/any-buddy";
    license = final.lib.licenses.wtfpl;
  };
}
```

If npm deps are needed, switch to `buildNpmPackage` with a lockfile
in `packages/ai-clis/locks/any-buddy-package-lock.json` and add
`npmDepsHash` to `hashes.json`. Follow the pattern from
`context7-mcp.nix`.

- [ ] **Step 3: Add any-buddy to sources.nix**

```nix
# In packages/ai-clis/sources.nix, add to the attrset:
any-buddy = generated."any-buddy";
```

Add alphabetically before `claude-code`.

- [ ] **Step 4: Register in default.nix overlay**

Add to `packages/ai-clis/default.nix`, alphabetically before
`claude-code`:

```nix
any-buddy-source = import ./any-buddy.nix {
  inherit final;
  nv = sources.any-buddy;
};
```

Note: named `any-buddy-source` to clarify it's a source tree, not a
CLI.

- [ ] **Step 5: Expose in flake.nix**

In `flake.nix`, in the `packages` attrset under the `# AI CLIs`
comment, add:

```nix
inherit (pkgs) any-buddy-source claude-code github-copilot-cli kiro-cli kiro-gateway;
```

(Replace the existing `inherit (pkgs) claude-code ...` line, adding
`any-buddy-source` alphabetically.)

- [ ] **Step 6: Verify build**

Run: `nix build .#any-buddy-source`

Expected: Builds successfully. `result/src/finder/worker.ts` exists.

- [ ] **Step 7: Format and commit**

```bash
treefmt packages/ai-clis/any-buddy.nix packages/ai-clis/sources.nix packages/ai-clis/default.nix flake.nix
git add packages/ai-clis/any-buddy.nix packages/ai-clis/sources.nix packages/ai-clis/default.nix flake.nix
git commit -m "feat(ai-clis): package any-buddy source for buddy salt search"
```

---

### Task 3: Implement mkBuddySalt derivation

**Files:**

- Create: `packages/ai-clis/buddy-salt.nix`

- [ ] **Step 1: Create buddy-salt.nix**

```nix
# mkBuddySalt — compute the buddy salt for a given user + trait combo.
#
# Runs any-buddy's worker script via Bun to brute-force search for a
# 15-character salt that produces the desired buddy traits when hashed
# with the user's account UUID.
#
# This derivation is independent of the claude-code version. It only
# re-runs when buddy options change.
{
  lib,
  bun,
  any-buddy-source,
  runCommand,
}: {
  userId,
  species,
  rarity ? "common",
  eyes ? "·",
  hat ? "none",
  shiny ? false,
  peak ? null,
  dump ? null,
}: let
  assertions = [
    {
      check = peak != dump || peak == null;
      msg = "withBuddy: peak and dump stats must differ";
    }
    {
      check = rarity == "common" -> hat == "none";
      msg = "withBuddy: common rarity forces hat = \"none\"";
    }
  ];
  failedAssertions = builtins.filter (a: !a.check) assertions;
  assertionErrors = builtins.map (a: a.msg) failedAssertions;
in
  assert assertionErrors == [] || throw (builtins.concatStringsSep "\n" assertionErrors);
    runCommand "buddy-salt-${species}-${rarity}" {
      nativeBuildInputs = [bun];

      # Pass as env vars to avoid shell interpolation issues with
      # special chars in eyes (·, ✦, etc.)
      inherit userId species rarity eyes hat;
      shinyFlag = lib.boolToString shiny;
      peakStat = if peak != null then peak else "";
      dumpStat = if dump != null then dump else "";
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      salt=$(bun ${any-buddy-source}/src/finder/worker.ts \
        "$userId" "$species" "$rarity" "$eyes" "$hat" \
        "$shinyFlag" "$peakStat" "$dumpStat" \
        | ${lib.getExe' (lib.getBin bun) "bun"} -e '
          const json = await Bun.stdin.text();
          process.stdout.write(JSON.parse(json).salt);
        ')

      # Validate salt is exactly 15 chars from expected charset
      if [[ ! "$salt" =~ ^[a-zA-Z0-9_-]{15}$ ]]; then
        echo "ERROR: invalid salt format: '$salt'" >&2
        exit 1
      fi

      echo -n "$salt" > $out
    '';
```

Note: The JSON parsing uses a second `bun -e` invocation rather than
adding `jq` as a dependency, since Bun is already required. If this
is awkward, swap for `${pkgs.jq}/bin/jq -r '.salt'` and add `jq` to
`nativeBuildInputs`.

- [ ] **Step 2: Verify the worker arg order**

Cross-reference with the spec research. The worker expects positional
args in this order: `userId species rarity eye hat [shiny] [peak] [dump]`.
The `--fnv1a` flag is NOT passed since we want wyhash (Bun default).
Verify this matches `src/finder/worker.ts` process.argv parsing.

- [ ] **Step 3: Format**

```bash
treefmt packages/ai-clis/buddy-salt.nix
```

- [ ] **Step 4: Commit**

```bash
git add packages/ai-clis/buddy-salt.nix
git commit -m "feat(ai-clis): add mkBuddySalt derivation for salt search"
```

---

### Task 4: Implement withBuddy patching derivation

**Files:**

- Create: `packages/ai-clis/with-buddy.nix`

- [ ] **Step 1: Create with-buddy.nix**

```nix
# withBuddy — patch claude-code binary with a pre-computed buddy salt.
#
# Replaces the default salt "friend-2026-401" (15 bytes) with the
# user's computed salt. The salt appears 3 times in compiled binaries
# (ELF/Mach-O) and 1 time in the JS bundle (cli.js).
#
# Uses python3 for binary-safe replacement — sd/sed are text-oriented
# and may corrupt ELF null bytes.
{
  lib,
  mkBuddySalt,
  python3,
  runCommand,
  sigtool ? null,
  stdenv,
}: claude-code: buddyOpts: let
  salt = builtins.readFile (mkBuddySalt buddyOpts);
  original = "friend-2026-401";
in
  runCommand "claude-code-buddy-${buddyOpts.species}-${buddyOpts.rarity or "common"}" {
    nativeBuildInputs =
      [python3]
      ++ lib.optional stdenv.hostPlatform.isDarwin sigtool;
    meta = claude-code.meta or {};
  } ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    cp -r ${claude-code} $out
    chmod -R u+w $out

    # Binary-safe 15-byte replacement (ASCII-only, same length)
    patched=0
    for f in $(find $out -type f \( -name "claude-code" -o -name "cli.js" -o -name "cli.mjs" \)); do
      python3 -c "
    import sys
    path = sys.argv[1]
    old = sys.argv[2].encode()
    new = sys.argv[3].encode()
    data = open(path, 'rb').read()
    count = data.count(old)
    if count > 0:
        patched = data.replace(old, new)
        open(path, 'wb').write(patched)
        print(f'Patched {count} occurrence(s) in {path}')
    " "$f" "${original}" "${salt}" && patched=1
    done

    if [[ "$patched" -eq 0 ]]; then
      echo "ERROR: salt '${original}' not found in any binary" >&2
      exit 1
    fi

    ${lib.optionalString stdenv.hostPlatform.isDarwin ''
      # macOS requires ad-hoc re-signing after binary modification
      codesign --force --sign - $out/bin/claude-code
    ''}
  '';
```

- [ ] **Step 2: Format**

```bash
treefmt packages/ai-clis/with-buddy.nix
```

- [ ] **Step 3: Commit**

```bash
git add packages/ai-clis/with-buddy.nix
git commit -m "feat(ai-clis): add withBuddy binary patching derivation"
```

---

### Task 5: Wire passthru into claude-code package

**Files:**

- Modify: `packages/ai-clis/claude-code.nix`
- Modify: `packages/ai-clis/default.nix`

- [ ] **Step 1: Add passthru.withBuddy to claude-code.nix**

The current `claude-code.nix` returns a `prev.claude-code.override`
call. We need to add `passthru.withBuddy` to the inner derivation.
The tricky part: the override pattern uses `buildNpmPackage` which
uses `finalAttrs`, so we add passthru via the attrset merge.

Modify `packages/ai-clis/claude-code.nix`:

```nix
# Claude Code — override nixpkgs' claude-code with nvfetcher-tracked version.
# Uses the same buildNpmPackage override pattern as nixos-config but with
# hashes tracked in the sidecar (not hardcoded).
{
  final,
  prev,
  nv,
  lockFile,
  withBuddyFn,
}:
let
  package = prev.claude-code.override (_: {
    buildNpmPackage = args:
      final.buildNpmPackage (finalAttrs: let
        a = (final.lib.toFunction args) finalAttrs;
      in
        a
        // {
          inherit (nv) version;
          src = final.fetchzip {
            url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${nv.version}.tgz";
            hash = nv.srcHash;
          };
          inherit (nv) npmDepsHash;
          postPatch = ''
            cp ${lockFile} package-lock.json

            # https://github.com/anthropics/claude-code/issues/15195
            substituteInPlace cli.js \
                  --replace-fail '#!/bin/sh' '#!/usr/bin/env sh'
          '';
          passthru = (a.passthru or {}) // {
            withBuddy = withBuddyFn package;
          };
        });
  });
in
  package
```

- [ ] **Step 2: Update default.nix to wire dependencies**

Modify `packages/ai-clis/default.nix` to pass `withBuddyFn` and
build the dependency chain:

```nix
# AI CLI package overlay.
_: final: prev: let
  sources = import ./sources.nix {inherit final;};

  mkBuddySalt = import ./buddy-salt.nix {
    inherit (final) bun runCommand;
    inherit (final) lib;
    any-buddy-source = final.any-buddy-source;
  };

  withBuddyFn = import ./with-buddy.nix {
    inherit (final) lib python3 runCommand stdenv;
    inherit mkBuddySalt;
    sigtool =
      if final.stdenv.hostPlatform.isDarwin
      then final.sigtool
      else null;
  };
in {
  any-buddy-source = import ./any-buddy.nix {
    inherit final;
    nv = sources.any-buddy;
  };
  claude-code = import ./claude-code.nix {
    inherit final prev withBuddyFn;
    nv = sources.claude-code;
    lockFile = ./locks/claude-code-package-lock.json;
  };
  github-copilot-cli = import ./copilot-cli.nix {
    inherit final prev;
    nv = sources.copilot-cli;
  };
  kiro-cli = import ./kiro-cli.nix {
    inherit final prev;
    nv = sources.kiro-cli;
    nv-darwin = sources.kiro-cli-darwin;
  };
  kiro-gateway = import ./kiro-gateway.nix {
    inherit final;
    nv = sources.kiro-gateway;
  };
}
```

- [ ] **Step 3: Verify base package still builds**

Run: `nix build .#claude-code`

Expected: Builds successfully, no regression from the passthru
addition.

- [ ] **Step 4: Format and commit**

```bash
treefmt packages/ai-clis/claude-code.nix packages/ai-clis/default.nix
git add packages/ai-clis/claude-code.nix packages/ai-clis/default.nix
git commit -m "feat(ai-clis): wire withBuddy passthru into claude-code"
```

---

### Task 6: Test withBuddy end-to-end

**Files:**

- No new files — manual verification

This task verifies that `pkgs.claude-code.withBuddy { ... }` produces
a working patched binary. Use a throwaway userId since we just need to
verify the mechanism works.

- [ ] **Step 1: Test basic withBuddy build**

Run:

```bash
nix build --expr '
  let
    flake = builtins.getFlake (toString ./.);
    pkgs = flake.packages.x86_64-linux;
  in
    pkgs.claude-code.withBuddy {
      userId = "test-user-00000000-0000-0000-0000-000000000000";
      species = "duck";
    }
'
```

Expected: Builds successfully. May take a few seconds for the salt
search (common duck is ~180 attempts).

- [ ] **Step 2: Verify salt was replaced**

```bash
# Check that the original salt is gone
python3 -c "
data = open('result/bin/claude-code', 'rb').read()
assert b'friend-2026-401' not in data, 'Original salt still present!'
print('OK: original salt not found')
"
```

Expected: Prints "OK: original salt not found"

- [ ] **Step 3: Verify binary runs**

Run: `result/bin/claude-code --version`

Expected: Prints version string without crash.

- [ ] **Step 4: Test assertion — peak == dump should fail**

Run:

```bash
nix build --expr '
  let
    flake = builtins.getFlake (toString ./.);
    pkgs = flake.packages.x86_64-linux;
  in
    pkgs.claude-code.withBuddy {
      userId = "test";
      species = "duck";
      peak = "CHAOS";
      dump = "CHAOS";
    }
' 2>&1 || true
```

Expected: Error message containing "peak and dump stats must differ".

- [ ] **Step 5: Test assertion — common + non-none hat should fail**

Run:

```bash
nix build --expr '
  let
    flake = builtins.getFlake (toString ./.);
    pkgs = flake.packages.x86_64-linux;
  in
    pkgs.claude-code.withBuddy {
      userId = "test";
      species = "duck";
      rarity = "common";
      hat = "wizard";
    }
' 2>&1 || true
```

Expected: Error message containing "common rarity forces hat".

- [ ] **Step 6: Test cache behavior — rebuild without options change**

Run `nix build` with the same args as Step 1 twice. Second build
should be instant (cached).

```bash
time nix build --expr '...' 2>&1  # first build
time nix build --expr '...' 2>&1  # second build — should be instant
```

Expected: Second build completes in <1s.

- [ ] **Step 7: Commit** (no files to commit — this was verification)

No commit needed. If any step failed, fix the issue in the relevant
task's file before proceeding.

---

### Task 7: Add buddy option to HM module

**Files:**

- Modify: `modules/ai/default.nix`

- [ ] **Step 1: Define buddySubmodule type**

Add a `let` binding for the buddy submodule options before the
`options.ai` block. Place after the existing `cfg = config.ai;` line:

```nix
buddySubmodule = types.submodule {
  options = {
    userId = mkOption {
      type = types.str;
      description = ''
        Claude account UUID (oauthAccount.accountUuid from
        ~/.claude.json). Consumer manages secrecy via sops,
        agenix, or similar.
      '';
    };

    species = mkOption {
      type = types.enum [
        "axolotl" "blob" "cactus" "capybara" "cat" "chonk"
        "dragon" "duck" "ghost" "goose" "mushroom" "octopus"
        "owl" "penguin" "rabbit" "robot" "snail" "turtle"
      ];
      description = "Buddy species.";
    };

    rarity = mkOption {
      type = types.enum [
        "common" "uncommon" "rare" "epic" "legendary"
      ];
      default = "common";
      description = ''
        Rarity tier. Higher rarities take longer to compute at
        build time (legendary ~1s, legendary+shiny ~30s,
        legendary+shiny+peak+dump may take minutes). The salt is
        cached — only recomputed when options change.
      '';
    };

    eyes = mkOption {
      type = types.enum ["·" "✦" "×" "◉" "@" "°"];
      default = "·";
      description = "Eye character.";
    };

    hat = mkOption {
      type = types.enum [
        "none" "beanie" "crown" "halo"
        "propeller" "tinyduck" "tophat" "wizard"
      ];
      default = "none";
      description = ''
        Hat accessory. Must be "none" for common rarity.
      '';
    };

    shiny = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Rainbow shimmer variant. Significantly increases build
        time (~100x more salt search attempts).
      '';
    };

    peak = mkOption {
      type = types.nullOr (types.enum [
        "CHAOS" "DEBUGGING" "PATIENCE" "SNARK" "WISDOM"
      ]);
      default = null;
      description = ''
        Preferred highest stat. null = accept whatever the salt
        produces. Increases search time ~5x.
      '';
    };

    dump = mkOption {
      type = types.nullOr (types.enum [
        "CHAOS" "DEBUGGING" "PATIENCE" "SNARK" "WISDOM"
      ]);
      default = null;
      description = ''
        Preferred lowest stat. Must differ from peak when both
        are set. null = accept whatever the salt produces.
      '';
    };
  };
};
```

- [ ] **Step 2: Add buddy option to ai.claude**

Inside the existing `ai.claude` submodule options (after `package`):

```nix
buddy = mkOption {
  type = types.nullOr buddySubmodule;
  default = null;
  description = ''
    Buddy companion customization. When set, the claude-code
    package is patched at build time with a salt that produces
    the specified companion for your account.
  '';
};
```

- [ ] **Step 3: Add assertions to config block**

In the `config = mkIf cfg.enable (mkMerge [` block, inside the
existing assertions list, add:

```nix
(lib.optionals (cfg.claude.buddy != null) [
  {
    assertion = cfg.claude.buddy.peak != cfg.claude.buddy.dump
      || cfg.claude.buddy.peak == null;
    message = "ai.claude.buddy: peak and dump stats must differ";
  }
  {
    assertion = cfg.claude.buddy.rarity == "common"
      -> cfg.claude.buddy.hat == "none";
    message = "ai.claude.buddy: common rarity forces hat = \"none\"";
  }
])
```

Append these to the existing `assertions` list using `++`.

- [ ] **Step 4: Wire buddy into package override**

In the Claude Code config section (`mkIf cfg.claude.enable`), add a
block that overrides the package when buddy is set. This should be
a new `mkIf` block merged into the existing Claude section:

```nix
(mkIf (cfg.claude.buddy != null) {
  ai.claude.package = mkDefault
    (cfg.claude.package.withBuddy cfg.claude.buddy);
})
```

Note: This uses `mkDefault` so a consumer can still override with a
manually patched package if needed.

- [ ] **Step 5: Format and verify evaluation**

```bash
treefmt modules/ai/default.nix
nix flake check
```

Expected: All existing checks pass, no regressions.

- [ ] **Step 6: Commit**

```bash
git add modules/ai/default.nix
git commit -m "feat(ai): add buddy option to claude module"
```

---

### Task 8: Add buddy option to devenv module (config parity)

**Files:**

- Modify: `modules/devenv/ai.nix`

- [ ] **Step 1: Add buddySubmodule to devenv ai module**

Mirror the exact same `buddySubmodule` type definition from Task 7.
To keep DRY, consider extracting the submodule to a shared location
if the duplication is excessive. However, since the project convention
is that HM and devenv modules are parallel but independent, duplicating
the type definition is acceptable (same pattern as the other submodule
options).

Add the same `buddySubmodule` let binding, `buddy` option under
`ai.claude`, and assertions as in Task 7.

- [ ] **Step 2: Wire buddy into package**

In the devenv Claude config section, add the same package override:

```nix
(mkIf (cfg.claude.buddy != null) {
  ai.claude.package = mkDefault
    (cfg.claude.package.withBuddy cfg.claude.buddy);
})
```

- [ ] **Step 3: Format and verify**

```bash
treefmt modules/devenv/ai.nix
nix flake check
```

Expected: All checks pass.

- [ ] **Step 4: Commit**

```bash
git add modules/devenv/ai.nix
git commit -m "feat(devenv): add buddy option to claude module (config parity)"
```

---

### Task 9: Add module evaluation tests

**Files:**

- Modify: `checks/module-eval.nix`

- [ ] **Step 1: Add buddy-enabled evaluation test**

Add after the existing `aiWithSettings` test:

```nix
# Test: ai module evaluates with buddy configured
aiBuddy = evalModule [
  self.homeManagerModules.default
  {
    config = {
      ai = {
        enable = true;
        claude = {
          enable = true;
          buddy = {
            userId = "test-00000000-0000-0000-0000-000000000000";
            species = "duck";
            rarity = "common";
          };
        };
      };
    };
  }
];
```

- [ ] **Step 2: Add the check derivation**

Add to the returned attrset:

```nix
ai-buddy-eval = pkgs.runCommand "ai-buddy-eval" {} ''
  echo "ai buddy evaluation: ${
    if aiBuddy.config.ai.claude.buddy != null
    then "buddy configured"
    else "buddy missing"
  }" > $out
'';
```

- [ ] **Step 3: Format and verify**

```bash
treefmt checks/module-eval.nix
nix flake check
```

Expected: All checks pass including the new `ai-buddy-eval`.

- [ ] **Step 4: Commit**

```bash
git add checks/module-eval.nix
git commit -m "test(ai): add buddy module evaluation check"
```

---

### Task 10: Add consumer documentation

**Files:**

- Create: `dev/docs/guides/buddy-customization.md`
- Modify: `dev/docs/SUMMARY.md`

- [ ] **Step 1: Create buddy customization guide**

````markdown
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
````

Your account UUID is in `~/.claude.json` under
`oauthAccount.accountUuid`. Treat it as a secret — use sops,
agenix, or a similar tool.

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

````

- [ ] **Step 2: Add to SUMMARY.md**

In `dev/docs/SUMMARY.md`, under the `# Guides` section, add
alphabetically:

```markdown
- [Buddy Customization](./guides/buddy-customization.md)
````

(Before "DevEnv Deep Dive".)

- [ ] **Step 3: Format**

```bash
treefmt dev/docs/guides/buddy-customization.md dev/docs/SUMMARY.md
```

- [ ] **Step 4: Verify doc site builds**

Run: `devenv tasks run generate:site`

Expected: Site builds without errors, new guide appears in nav.

- [ ] **Step 5: Commit**

```bash
git add dev/docs/guides/buddy-customization.md dev/docs/SUMMARY.md
git commit -m "docs: add buddy customization guide"
```

---

### Task 11: Update plan.md backlog

**Files:**

- Modify: `docs/plan.md`

- [ ] **Step 1: Mark backlog item as done**

Change the `claude-code.withBuddy` backlog item from `- [ ]` to
`- [x]` and add a completion note.

- [ ] **Step 2: Format and commit**

```bash
treefmt docs/plan.md
git add docs/plan.md
git commit -m "docs(plan): mark withBuddy as complete"
```
