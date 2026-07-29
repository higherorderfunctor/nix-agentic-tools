# Typed model + thinking config / effort-pin reconciliation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Claude's `settings.effortLevel` actually stick (defeat the
per-model launch-effort pin), type it as a real enum, add soft-enum model hints
for Claude + Kiro, restore DRY across the three settings-merge call sites, add
model-staleness checks, and scrub the phantom `ai.settings` from the docs.

**Architecture:** Five workstreams from the converged design doc
`docs/plans/typed-model-and-thinking-config-convergence.md`, delivered as 7
atomic commits. Thinking-level enum is **binary-extracted** into a committed
sidecar (`overlays/claude-code-extracted.json`) read eval-purely (no IFD);
models are **hand-curated soft-enums** (`either (enum known) str`) validated by
a live/offline staleness check. The launch-pin acknowledgment flags are
reconciled into mutable `~/.claude.json` at HM activation through a shared
settings-merge helper that all three CLIs now use.

**Tech Stack:** Nix (home-manager + devenv module factories under
`packages/*/lib/mk*.nix`), `lib.evalModules` eval tests in
`checks/module-eval.nix`, `runCommand` flake checks, devenv tasks, `jq`/`grep`
shell extraction.

---

## Conventions for every task (read once)

These gates apply to **every** task. They are not repeated verbatim in each step
— follow them whenever a step says "validate" or "commit".

1. **Format after every edit.** Run `treefmt <file>` on each changed file (it
   drives alejandra for Nix and prettier/biome for md/json). AGENTS.md
   "Validation → Formatting".
2. **`git add` new files before any `nix flake check` / `nix build`.** Nix
   flakes only see git-tracked files; an untracked `.json`/`.nix` is invisible
   to checks and to derivations that scan the tree.
   `.claude/rules/nix-standards.md` § Flake Source Visibility.
3. **Validation entrypoint is `nix flake check`** (eval + all `checks.*`). Run a
   single check with `nix build .#checks.x86_64-linux.<name>`.
4. **Never hand-edit generated instruction files.** `.claude/rules/*.md`,
   `.github/instructions/*.md`, `.kiro/steering/*.md`, `CLAUDE.md`, `AGENTS.md`
   are generated from `dev/fragments/**`. Regenerate with
   `devenv tasks run --mode before generate:instructions`.
5. **Commits go through the repo's stacked-commit skills, not raw git.** Each
   task ends with one commit; use `/stack-plan` (or the appropriate `/stack-*`
   skill) to record it with the exact conventional-commit message given.
   AGENTS.md "Skill Routing — MANDATORY". Do **not** hand-run
   git-branchless/absorb/revise.
6. **Each commit must be independently `nix flake check`-green.** The ordering
   below guarantees this; do not reorder.
7. **Shell in activation/heredocs:** the shared activation helper keeps
   `set -eu` (matching the existing kiro/copilot activation scripts it replaces)
   and uses absolute `${coreutils}/bin/…` / `${jq}` paths
   (`.claude/rules/nix-standards.md` § Shell Wrappers). Standalone update/task
   scripts use full strict mode `set -euETo pipefail; shopt -s inherit_errexit`
   (AGENTS.md "Bash"). **Never `exit` inside a `home.activation` block** (it
   inlines into the outer `set -eu` activation script).
8. **IFD rule (inviolable):** eval-time `readFile`/`fromJSON` may target only
   **committed source files**, never a derivation/`runCommand` output. The grep
   outputs (`passthru.extracted`) are consumed only by `nix build` (the drift
   check + the update script), never read at eval. `.claude/rules/overlays.md` §
   IFD Patterns.

---

## File Structure

**New files**

| File                                  | Responsibility                                                                                                    |
| ------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `overlays/claude-code-extracted.json` | Committed SSOT: `{launchEffortPins, effortLevels}` extracted from the binary. Read eval-purely by `mkClaude.nix`. |
| `packages/claude-code/models.json`    | Hand-curated Claude model ids (dash notation) for the soft-enum hint + staleness check.                           |
| `packages/kiro-cli/models.json`       | Hand-curated Kiro model ids (dot notation).                                                                       |
| `checks/claude-code-extracted.nix`    | Drift flake check: `passthru.extracted` vs committed JSON. **Blocking.**                                          |
| `checks/model-staleness-claude.nix`   | Advisory flake check: binary `firstParty:` ids vs committed `models.json`. **Warn, never fail.**                  |
| `dev/tasks/check.nix`                 | devenv task `check:model-staleness` (Kiro live query + Copilot note).                                             |

**Modified files**

| File                                     | Change                                                                                                                                  |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `lib/ai/hm-helpers.nix`                  | Rewrite dead `mkSettingsActivationScript` into the shared inline-heredoc merger.                                                        |
| `lib/ai/lib.nix` → `overlays/lib.nix`    | Add `mkClaudeExtract` snippet + `extraExtract` param to `mkUpdateScript`.                                                               |
| `overlays/claude-code.nix`               | `finalAttrs` conversion; `passthru.extracted`; wire `extraExtract`.                                                                     |
| `packages/claude-code/lib/mkClaude.nix`  | Typed `settings` submodule (`effortLevel` enum + `model` soft-enum), `unpinLaunchEffort` option, HM null-filter, reconciler activation. |
| `packages/kiro-cli/lib/mkKiro.nix`       | `defaultModel` → soft-enum; route settings merge through shared helper.                                                                 |
| `packages/copilot-cli/lib/mkCopilot.nix` | Route settings merge through shared helper.                                                                                             |
| `checks/module-eval.nix`                 | New eval tests (enum rejection, null-filter, soft-enum, reconciler).                                                                    |
| `flake.nix`                              | Register the two new flake checks.                                                                                                      |
| `devenv.nix`                             | Register `dev/tasks/check.nix`.                                                                                                         |
| WS5 docs (10 files)                      | Scrub phantom `ai.settings`.                                                                                                            |

---

## Task 1 — WS5: scrub the phantom `ai.settings` from docs

**Goal:** `ai.settings` / `ai.settings.model` / `ai.settings.telemetry` is a
documented-but-unimplemented normalized option (0 `.nix` implementations).
Remove every doc reference; models/settings are per-CLI only. No code changes.

**Files:**

- Modify: `devshell/docs-site/default.nix` (aiMappingTable generator rows)
- Modify: `devshell/docs-site/pages/ai-mapping.md`
- Modify: `devshell/docs-site/pages/home-manager-footer.md`
- Modify: `dev/fragments/ai-module/ai-module-fanout.md`
- Modify: `dev/fragments/hm-modules/module-conventions.md`
- Modify: `dev/references/config-parity.md`
- Modify: `dev/docs/concepts/config-parity.md`
- Modify: `dev/docs/concepts/unified-ai-module.md`
- Modify: `dev/docs/getting-started/home-manager.md`
- Leave (design archive, optionally annotate):
  `dev/notes/ai-transformer-design.md`
- Regenerated: `.claude/rules/ai-module.md`,
  `.claude/rules/hm-module-conventions.md` (+ Copilot/Kiro twins) — produced by
  the regenerate step, never hand-edited.

- [ ] **Step 1: Re-confirm the live anchor set before editing**

The convergence doc's line numbers are 3 days old. Re-locate every hit so the
edits below target current text:

```bash
RIPGREP_CONFIG_PATH=/dev/null rg --no-config -n "ai\.settings" \
  /home/caubut/Documents/projects/nix-agentic-tools-ideation \
  --glob '!**/.claude/rules/**' --glob '!**/.github/instructions/**' \
  --glob '!**/.kiro/steering/**'
```

Expected: hits in the 9 source docs below (plus
`dev/notes/ai-transformer-design.md`, which we keep). The `.claude/rules` /
`.github/instructions` / `.kiro/steering` hits are **generated** — excluded
here, fixed by Step 10's regeneration.

- [ ] **Step 2: Drop the two phantom rows from the ai-mapping generator**

In `devshell/docs-site/default.nix`, delete the `settings.model` and
`settings.telemetry` rows from the `aiMappingTable` snippet (their left column
is the phantom `ai.settings.*` key). Remove these two lines:

```
| `settings.model`       | `programs.claude-code.settings.model` | `programs.copilot-cli.settings.model`       | `programs.kiro-cli.settings.chat.defaultModel` |
| `settings.telemetry`   | --                                    | --                                          | `programs.kiro-cli.settings.telemetry.enabled` |
```

- [ ] **Step 3: Same two rows in the static ai-mapping page**

In `devshell/docs-site/pages/ai-mapping.md`, delete the identical two rows (the
phantom-keyed `settings.model` / `settings.telemetry` rows), and replace the
phantom code-block example near the bottom. Replace:

```nix
ai.settings.model = "claude-sonnet-4";               # mkDefault (1000)
programs.copilot-cli.settings.model = "gpt-4o";      # normal (100) -- wins
```

with:

```nix
programs.claude-code.settings.model = "claude-sonnet-4";   # per-CLI
programs.copilot-cli.settings.model = "gpt-4o";            # per-CLI
```

- [ ] **Step 4: home-manager footer priority example**

In `devshell/docs-site/pages/home-manager-footer.md`, rewrite the override
example. Replace:

```nix
# Shared default
ai.settings.model = "claude-sonnet-4";

# Copilot override (normal priority wins over mkDefault)
programs.copilot-cli.settings.model = "gpt-4o";
```

with:

```nix
# Per-CLI model selection (each CLI owns its own settings)
programs.claude-code.settings.model = "claude-sonnet-4";
programs.copilot-cli.settings.model = "gpt-4o";
```

and adjust the surrounding prose so it no longer claims `ai.settings.*` fans out
at `mkDefault` (keep the git-preset `mkDefault` sentence, which is real).

- [ ] **Step 5: Delete the normalized-settings bullet from the ai-module
      fragment**

In `dev/fragments/ai-module/ai-module-fanout.md`, delete this bullet verbatim:

```
- `ai.settings.{model,telemetry}` — normalized settings; each
  ecosystem has a different native option path (Claude has no
  model setting; Copilot has `settings.model`; Kiro has
  `settings.chat.defaultModel`).
```

- [ ] **Step 6: Remove `ai.settings` from the module-conventions fragment list**

In `dev/fragments/hm-modules/module-conventions.md`, edit the "Flat at top
level" paragraph. Change:

```
**Flat at top level for cross-ecosystem.** `ai.skills`,
`ai.instructions`, `ai.lspServers`, `ai.settings`, and
`ai.environmentVariables` are NOT nested inside a per-ecosystem
```

to:

```
**Flat at top level for cross-ecosystem.** `ai.skills`,
`ai.instructions`, `ai.lspServers`, and
`ai.environmentVariables` are NOT nested inside a per-ecosystem
```

- [ ] **Step 7: dev/references/config-parity.md — delete row + section**

Delete the surface-table row whose Settings cell references `ai.settings`:

```
| Settings              | N/A                           | `ai.settings`, per-CLI `.settings` (typed + freeform)  | `ai.settings`, per-CLI `.settings` (typed + freeform)  |
```

and delete the entire "Normalized Settings (ai.settings)" section (its heading,
the paragraph, and the model/telemetry table). Keep all per-CLI rows.

- [ ] **Step 8: dev/docs/concepts/config-parity.md — rewrite the settings row**

Replace:

```
| Settings                | `ai.settings`             | `ai.settings`                   | Per-CLI JSON generation                       |
```

with:

```
| Settings                | Per-CLI via `.settings`   | Per-CLI via `.settings`         | Per-CLI JSON generation                       |
```

- [ ] **Step 9: dev/docs concepts + getting-started examples**

In `dev/docs/concepts/unified-ai-module.md`, rewrite the Priority code example
to per-CLI form:

```nix
# Each CLI owns its own settings path
programs.claude-code.settings.model = "claude-sonnet-4";
programs.copilot-cli.settings.model = "gpt-4o";
programs.kiro-cli.settings.chat.defaultModel = "claude-sonnet-4";
```

and update the numbered "priority chain" prose so it no longer references
`ai.settings.model` fanning out at `mkDefault` (the example now shows
independent per-CLI settings, so reframe as "each CLI's normal-priority
setting").

In `dev/docs/getting-started/home-manager.md`:

- Change the inline comment
  `settings.model = "gpt-4o";  # override ai.settings.model for Copilot` to
  `settings.model = "gpt-4o";  # Copilot's model setting`.
- Delete the `settings.model` and `settings.telemetry` rows from the "What gets
  generated" table (left column was the phantom `ai.*` key).

- [ ] **Step 10: (optional) annotate the design archive — do not delete**

`dev/notes/ai-transformer-design.md` is a design archive of the rejected
normalized-settings idea. Leave the body. Optionally add one line near its first
`ai.settings.model` mention:
`**Rejected:** models are ecosystem-specific; no normalized ai.settings was implemented (see WS5).`

- [ ] **Step 11: Regenerate the per-ecosystem instruction files**

The fragment edits (Steps 5–6) feed generated rule/instruction/steering files.
Regenerate (never hand-edit them):

```bash
devenv tasks run --mode before generate:instructions
```

Then `git status` — expect changes under `.claude/rules/`,
`.github/instructions/`, `.kiro/steering/` for the `ai-module` and
`hm-module-conventions` categories. `treefmt` any that aren't already formatted
by the derivation.

- [ ] **Step 12: Verify zero stragglers**

```bash
RIPGREP_CONFIG_PATH=/dev/null rg --no-config "ai\.settings" \
  /home/caubut/Documents/projects/nix-agentic-tools-ideation \
  --glob '!dev/notes/ai-transformer-design.md'
```

Expected: **no output** (every reference scrubbed except the design archive).
Then `git add -A` the changed docs + regenerated files and run `nix flake check`
(expected: passes — only cspell/formatting touch docs).

- [ ] **Step 13: Commit (via the stacked-commit skill)**

Message:

```
docs(ai): drop unimplemented normalized ai.settings; models are per-CLI
```

---

## Task 2 — WS4: route copilot + kiro settings merge through a shared helper

**Goal:** `lib/ai/hm-helpers.nix:mkSettingsActivationScript` is dead code;
Copilot and Kiro each inline a near-identical `jq -s '.[0] * .[1]'` activation
merge. Rewrite the helper to the **inline-heredoc** shape (so `module-eval` can
still assert on rendered content) and route both call sites through it. This
also primes the helper for Claude's reconciler in Task 5.

**Files:**

- Modify: `lib/ai/hm-helpers.nix:134-161` (rewrite `mkSettingsActivationScript`)
- Modify: `packages/copilot-cli/lib/mkCopilot.nix:118-129,315-338`
- Modify: `packages/kiro-cli/lib/mkKiro.nix:370-393`

- [ ] **Step 1: Confirm the assertions the refactor must preserve**

Read the two activation-text tests so the refactor keeps them green:

```bash
RIPGREP_CONFIG_PATH=/dev/null rg --no-config -n \
  'copilotSettingsMerge|kiroSettingsMerge|hasInfix "jq"' \
  checks/module-eval.nix
```

`module-copilot-hm-writes-settings-json-activation` asserts the activation text
contains `gpt-4` **and** `jq`; `module-kiro-hm-writes-settings-activation`
asserts `claude-sonnet-4` **and** `jq`. The helper therefore MUST inline the
settings JSON via heredoc (not a store-path read) and invoke `jq` by an absolute
path (the store path string contains `jq`).

- [ ] **Step 2: Rewrite the shared helper**

In `lib/ai/hm-helpers.nix`, replace the dead helper (the
`# ── Settings activation script ──` block, lines ~134-161) with:

```nix
  # ── Settings activation script ───────────────────────────────────────
  # Shell snippet that merges Nix-declared JSON settings into an existing
  # mutable JSON config file at HM activation time. The settings JSON is
  # INLINED via a quoted heredoc (not a store-path read) so module-eval
  # tests can assert on rendered content and the merge stays atomic.
  # `jq -s '.[0] * .[1]'` makes Nix-declared values win on key conflict
  # while preserving runtime-added keys (oauth tokens in ~/.claude.json,
  # trusted_folders in copilot settings.json, etc.).
  #
  # configFile:   path relative to $HOME (".copilot/settings.json",
  #               ".kiro/settings/cli.json", ".claude.json").
  # settingsJson: JSON string to merge (caller `builtins.toJSON`'s it;
  #               Kiro flattens dot-keys first).
  # jq:           absolute jq binary path ("${pkgs.jq}/bin/jq").
  # coreutils:    coreutils package (absolute paths for every command).
  mkSettingsActivationScript = {
    configFile,
    settingsJson,
    jq,
    coreutils,
  }: let
    parentDir = builtins.dirOf configFile;
  in ''
    set -eu
    TARGET_DIR="$HOME/${parentDir}"
    CONFIG_FILE="$HOME/${configFile}"
    ${coreutils}/bin/mkdir -p "$TARGET_DIR"
    NIX_SETTINGS=$(${coreutils}/bin/mktemp)
    ${coreutils}/bin/cat > "$NIX_SETTINGS" <<'NAT_SETTINGS_EOF'
    ${settingsJson}
    NAT_SETTINGS_EOF
    if [ ! -f "$CONFIG_FILE" ]; then
      ${coreutils}/bin/cp "$NIX_SETTINGS" "$CONFIG_FILE"
    else
      TMP=$(${coreutils}/bin/mktemp)
      ${jq} -s '.[0] * .[1]' "$CONFIG_FILE" "$NIX_SETTINGS" > "$TMP"
      ${coreutils}/bin/mv "$TMP" "$CONFIG_FILE"
    fi
    ${coreutils}/bin/rm -f "$NIX_SETTINGS"
    ${coreutils}/bin/chmod 644 "$CONFIG_FILE"
  '';
```

Indentation note: the heredoc terminator `NAT_SETTINGS_EOF` and the
`${settingsJson}` line sit at the block's minimum indentation, so Nix's `''`
dedent puts them at column 0 — the heredoc closes correctly. `settingsJson` is
single-line `toJSON` output, so the body is exactly one line.

- [ ] **Step 3: Route Copilot through the helper**

In `packages/copilot-cli/lib/mkCopilot.nix`, add a `helpers` import to the HM
`let` (next to `aiCommon` at ~line 130):

```nix
      aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};
      helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
```

Then replace the inline activation block (the
`(lib.mkIf (cfg.settings != {}) (let settingsJsonText = …; in { home.activation.copilotSettingsMerge = … ''…''; }))`
at lines ~315-338) with:

```nix
        (lib.mkIf (cfg.settings != {}) {
          home.activation.copilotSettingsMerge =
            lib.hm.dag.entryAfter ["writeBoundary"] (helpers.mkSettingsActivationScript {
              configFile = "${cfg.configDir}/settings.json";
              settingsJson = builtins.toJSON cfg.settings;
              jq = "${pkgs.jq}/bin/jq";
              coreutils = pkgs.coreutils;
            });
        })
```

- [ ] **Step 4: Route Kiro through the helper**

In `packages/kiro-cli/lib/mkKiro.nix`, the HM config already imports `helpers`
(line ~187). Replace the inline activation block (the
`(lib.mkIf (filteredSettings != {}) (let settingsJsonText = …; in { home.activation.kiroSettingsMerge = … ''…''; }))`
at lines ~370-393) with:

```nix
        (lib.mkIf (filteredSettings != {}) {
          home.activation.kiroSettingsMerge =
            lib.hm.dag.entryAfter ["writeBoundary"] (helpers.mkSettingsActivationScript {
              configFile = "${cfg.configDir}/settings/cli.json";
              settingsJson = builtins.toJSON flatSettings;
              jq = "${pkgs.jq}/bin/jq";
              coreutils = pkgs.coreutils;
            });
        })
```

`flatSettings` (the dot-key-flattened, null-filtered settings) is already in
scope in the HM `let`.

- [ ] **Step 5: Run the two existing activation tests (must stay green)**

```bash
treefmt lib/ai/hm-helpers.nix packages/copilot-cli/lib/mkCopilot.nix packages/kiro-cli/lib/mkKiro.nix
nix build .#checks.x86_64-linux.module-copilot-hm-writes-settings-json-activation
nix build .#checks.x86_64-linux.module-kiro-hm-writes-settings-activation
```

Expected: both build (PASS). They assert the merged settings value + `jq` appear
in the activation text, which the inline-heredoc helper preserves.

- [ ] **Step 6: Full check**

```bash
nix flake check
```

Expected: passes. (No new options; behavior is identical, source is DRY.)

- [ ] **Step 7: Commit**

```
refactor(ai): route copilot+kiro settings merge through shared helper
```

---

## Task 3 — WS1: extract launch-effort pins + effort levels to a committed sidecar

**Goal:** Produce `overlays/claude-code-extracted.json` from the packaged binary
(`{launchEffortPins, effortLevels}`), regenerate it inside the update script,
and gate it with a blocking drift check. Single grep source of truth; IFD-safe
(eval reads only the committed JSON, never the grep output).

**Files:**

- Modify: `overlays/lib.nix` (add `mkClaudeExtract`; add `extraExtract` param)
- Modify: `overlays/claude-code.nix` (finalAttrs conversion;
  `passthru.extracted`; wire `extraExtract`)
- Create: `overlays/claude-code-extracted.json` (generated, then committed)
- Create: `checks/claude-code-extracted.nix`
- Modify: `flake.nix:202-212` (register the check)

- [ ] **Step 1: Add the shared extraction snippet to `overlays/lib.nix`**

Add `mkClaudeExtract` to the attrset returned by `overlays/lib.nix` (e.g. after
`mkUpdateScript`). It greps the binary once and emits the combined JSON, with
the two failure-hardening assertions baked in (§6 of the design doc):

```nix
  # Grep claude's binary for its launch-effort pin keys and the effort
  # enum, emitting `{launchEffortPins, effortLevels}` to `dest` (default
  # stdout). Single source of the grep logic — used by claude-code.nix's
  # passthru.extracted (and, transitively, by mkUpdateScript). Fails loud
  # (exit 1) if the pin grep is empty or the effort anchor != exactly one
  # match, so an upstream rename breaks the build instead of silently
  # extracting nothing.
  #   bin:  absolute path to the claude binary.
  #   pkgs: nixpkgs set (gnugrep, coreutils, jq).
  #   dest: output path (default "/dev/stdout"; pass "$out" in runCommand).
  mkClaudeExtract = {
    bin,
    pkgs,
    dest ? "/dev/stdout",
  }: ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    grep="${pkgs.gnugrep}/bin/grep"
    jq="${pkgs.jq}/bin/jq"
    sort="${pkgs.coreutils}/bin/sort"
    wc="${pkgs.coreutils}/bin/wc"

    pins=$("$grep" -aoE 'unpin[A-Za-z0-9]+LaunchEffort' "${bin}" | "$sort" -u || true)
    if [ -z "$pins" ]; then
      echo "claude-extract: no unpin*LaunchEffort keys found (upstream renamed the launch-pin mechanism)" >&2
      exit 1
    fi

    anchor='effortLevel:y.enum(["low","medium","high","xhigh"])'
    matchCount=$("$grep" -aoF "$anchor" "${bin}" | "$wc" -l || true)
    if [ "$matchCount" -ne 1 ]; then
      echo "claude-extract: effort anchor matched $matchCount times (expected 1; upstream changed the validator)" >&2
      exit 1
    fi
    levels=$(printf '%s' "$anchor" | "$grep" -oE '\[[^]]*\]')

    pinsJson=$(printf '%s\n' "$pins" | "$jq" -R . | "$jq" -s .)
    "$jq" -n --argjson pins "$pinsJson" --argjson levels "$levels" \
      '{launchEffortPins: $pins, effortLevels: $levels}' > "${dest}"
  '';
```

- [ ] **Step 2: Add an `extraExtract` hook to `mkUpdateScript`**

In `overlays/lib.nix`, add an optional `extraExtract ? ""` parameter to
`mkUpdateScript` and run it after the sidecar is written. Change the signature:

```nix
  mkUpdateScript = {
    pname,
    versionCheck,
    platforms,
    sourcesFile ? "overlays/${pname}-sources.json",
    extraExtract ? "",
    pkgs,
  }:
```

and append `${extraExtract}` immediately after the existing
`echo "Updated ${sourcesFile}"` line at the end of the script body:

```nix
      mv "$tmp" "${sourcesFile}"
      echo "Updated ${sourcesFile}"
      ${extraExtract}
    '';
```

Kiro/copilot pass no `extraExtract`, so they are unaffected.

- [ ] **Step 3: Convert `overlays/claude-code.nix` to `finalAttrs` + add
      `passthru.extracted`**

The derivation currently uses the attrset `mkDerivation` form, which cannot
reference its own `$out`. Convert to the `finalAttrs` form (precedent: the
mcp/git overlays) and move `passthru` to an explicit attr. Replace the
`stdenv.mkDerivation { … }` (lines ~34-69) with:

```nix
  stdenv.mkDerivation (finalAttrs: {
    pname = "claude-code";
    inherit (sources) version;
    src = fetchurl {inherit (platformSrc) url hash;};
    dontUnpack = true;
    dontBuild = true;
    dontPatchELF = true;
    dontStrip = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      install -Dm755 $src $out/bin/claude
      ${lib.optionalString stdenv.hostPlatform.isLinux ''
        patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
          $out/bin/claude
      ''}
      runHook postInstall
    '';
    passthru = {
      updateScript = vu.mkUpdateScript {
        pname = "claude-code";
        versionCheck.cmd = "${ourPkgs.curl}/bin/curl -s ${manifestBase}/latest";
        platforms = {
          "x86_64-linux" = ver: "${manifestBase}/${ver}/linux-x64/claude";
          "aarch64-darwin" = ver: "${manifestBase}/${ver}/darwin-arm64/claude";
        };
        # Regenerate the committed sidecar from the freshly-bumped binary
        # in the SAME update/claude-code PR (no intra-PR drift). Builds the
        # pure passthru.extracted against the just-written sources.json
        # (dirty-tracked → flake eval sees the new version) and copies it
        # over the committed path. Single grep source (mkClaudeExtract via
        # passthru) — DRY with the drift check.
        extraExtract = ''
          echo "claude-code: regenerating overlays/claude-code-extracted.json"
          extracted=$(${ourPkgs.nix}/bin/nix build --no-link --print-out-paths \
            ".#claude-code.passthru.extracted")
          ${ourPkgs.coreutils}/bin/cp "$extracted" overlays/claude-code-extracted.json
          ${ourPkgs.coreutils}/bin/chmod 644 overlays/claude-code-extracted.json
          echo "claude-code: wrote overlays/claude-code-extracted.json"
        '';
        pkgs = ourPkgs;
      };
      # Pure grep of THIS package's own binary → committed-sidecar shape.
      # IFD-safe: consumed ONLY by `nix build` (drift check + update
      # script), NEVER readFile'd at eval. See overlays.md § IFD Patterns.
      extracted = ourPkgs.runCommandLocal "claude-code-extracted.json" {} (
        vu.mkClaudeExtract {
          bin = "${finalAttrs.finalPackage}/bin/claude";
          pkgs = ourPkgs;
          dest = "$out";
        }
      );
    };
    meta = {
      mainProgram = "claude";
      license = lib.licenses.unfree;
      description = "Anthropic's Claude Code CLI";
    };
  })
```

(The unfree guard in `overlays/default.nix` wraps claude-code in a `symlinkJoin`
that **carries `passthru`** — so
`self.packages.<sys>.claude-code.passthru.extracted` resolves through the
wrapper.)

- [ ] **Step 4: Generate the committed sidecar (don't hand-write it)**

`git add` the two modified overlay files first (flake source visibility), then
build the extractor and commit its output verbatim so the JSON provably matches
the binary:

```bash
git add overlays/lib.nix overlays/claude-code.nix
extracted=$(nix build .#claude-code.passthru.extracted --no-link --print-out-paths)
cp "$extracted" overlays/claude-code-extracted.json
chmod u+w overlays/claude-code-extracted.json
treefmt overlays/claude-code-extracted.json
cat overlays/claude-code-extracted.json
```

Expected content (current binary, 2.1.159):

```json
{
  "launchEffortPins": ["unpinOpus47LaunchEffort", "unpinOpus48LaunchEffort"],
  "effortLevels": ["low", "medium", "high", "xhigh"]
}
```

Then `git add overlays/claude-code-extracted.json`.

- [ ] **Step 5: Write the blocking drift check**

Create `checks/claude-code-extracted.nix`:

```nix
# Drift check — the committed overlays/claude-code-extracted.json must
# match what the packaged claude binary actually contains. Blocking
# (pins/levels must be exact for correctness). The build of
# passthru.extracted also enforces the non-empty / count==1 hardening
# baked into vu.mkClaudeExtract.
{
  lib,
  pkgs,
  self,
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  extracted = self.packages.${system}.claude-code.passthru.extracted;
  committed = ../overlays/claude-code-extracted.json;
in {
  claude-code-extracted = pkgs.runCommand "claude-code-extracted-drift" {} ''
    jq="${pkgs.jq}/bin/jq"
    if "$jq" -e -n --slurpfile a ${extracted} --slurpfile b ${committed} \
      '$a == $b' > /dev/null; then
      echo "ok — overlays/claude-code-extracted.json matches the packaged binary" > $out
    else
      echo "FAIL: overlays/claude-code-extracted.json is out of sync with the claude binary." >&2
      echo "--- committed ---" >&2
      "$jq" -S . ${committed} >&2
      echo "--- extracted from binary ---" >&2
      "$jq" -S . ${extracted} >&2
      echo "" >&2
      echo "Regenerate: nix build .#claude-code.passthru.extracted --no-link --print-out-paths" >&2
      echo "then cp the result over overlays/claude-code-extracted.json and 'git add' it." >&2
      exit 1
    fi
  '';
}
```

- [ ] **Step 6: Register the check in `flake.nix`**

In the `checks = forAllSystems (system: let … )` block (lines ~202-212), add the
import alongside the others and append it to the merge:

```nix
      cacheHitParityCheck = import ./checks/cache-hit-parity.nix {inherit inputs lib pkgs self;};
      claudeExtractedCheck = import ./checks/claude-code-extracted.nix {inherit lib pkgs self;};
```

```nix
      bareCommandsCheck // cacheHitParityCheck // claudeExtractedCheck // factoryChecks // formattingCheck // fragmentsChecks // moduleChecks // pnpmFetcherParityCheck);
```

- [ ] **Step 7: Verify the drift check passes, then prove it fails on drift**

```bash
git add checks/claude-code-extracted.nix flake.nix overlays/claude-code-extracted.json
treefmt checks/claude-code-extracted.nix flake.nix
nix build .#checks.x86_64-linux.claude-code-extracted && cat result
```

Expected:
`ok — overlays/claude-code-extracted.json matches the packaged binary`.

Now prove it catches drift (TDD red): edit `overlays/claude-code-extracted.json`
to drop `"unpinOpus48LaunchEffort"`, rebuild:

```bash
nix build .#checks.x86_64-linux.claude-code-extracted
```

Expected: **FAIL** with the committed-vs-extracted diff. Restore the file
(`git checkout overlays/claude-code-extracted.json`) and rebuild to green.

- [ ] **Step 8: Full check + commit**

```bash
nix flake check
```

Expected: passes (drift check builds claude-code, substituted from cachix).

```
feat(claude-code): extract launch-effort pins + effort levels to committed sidecar
```

---

## Task 4 — WS1/WS2: typed `effortLevel` enum + `model` soft-enum settings submodule (Claude)

**Goal:** Convert Claude's `settings` from `attrsOf anything` to a typed
submodule + freeform passthrough (mirroring Kiro), delivering the strict 4-value
`effortLevel` enum (from the committed sidecar) and the `model` soft-enum hint.
Add the `unpinLaunchEffort` option (consumed in Task 5). Null-filter typed keys
on the HM side so upstream never receives `effortLevel = null` / `model = null`.

**Files:**

- Create: `packages/claude-code/models.json`
- Modify: `packages/claude-code/lib/mkClaude.nix` (top `let`, `settings` option,
  `unpinLaunchEffort` option, HM null-filter at line ~237)
- Modify: `checks/module-eval.nix` (new tests)

- [ ] **Step 1: Create the curated Claude model list**

Create `packages/claude-code/models.json` (dash notation; current,
non-deprecated set the user actually selects):

```json
["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"]
```

`treefmt` it and `git add packages/claude-code/models.json`.

- [ ] **Step 2: Add eval-pure reads to the top of `mkClaude.nix`**

`packages/claude-code/lib/mkClaude.nix` currently goes straight into
`lib.ai.app.mkAiApp { … }`. Wrap it in a `let` that reads the committed source
JSONs (IFD-free — git-tracked files, never derivation outputs):

```nix
{
  lib,
  pkgs,
  ...
}: let
  # Eval-pure reads of COMMITTED source JSON (no IFD). See overlays.md
  # § IFD Patterns.
  extracted =
    builtins.fromJSON (builtins.readFile ../../../overlays/claude-code-extracted.json);
  knownClaudeModels =
    builtins.fromJSON (builtins.readFile ../models.json);
in
  lib.ai.app.mkAiApp {
    name = "claude";
    # … rest unchanged …
```

(Close the `let` by ensuring the final `}` of `mkAiApp { … }` ends the file with
no trailing change.)

- [ ] **Step 3: Replace the `settings` option with a typed submodule**

In the shared `options = { … }` block, replace the current `settings` option
(lines ~44-51, `type = lib.types.attrsOf lib.types.anything;`) with:

```nix
    settings = lib.mkOption {
      type = lib.types.submodule {
        freeformType = (pkgs.formats.json {}).type;
        options = {
          effortLevel = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum extracted.effortLevels);
            default = null;
            description = ''
              Persisted Claude effort level. The valid set
              (low/medium/high/xhigh) is extracted from the packaged binary
              into overlays/claude-code-extracted.json. 'max' is session-only
              via /effort and cannot be persisted.
            '';
          };
          model = lib.mkOption {
            type = lib.types.nullOr
              (lib.types.either (lib.types.enum knownClaudeModels) lib.types.str);
            default = null;
            description = ''
              Claude model id. Known ids (packages/claude-code/models.json)
              autocomplete; any string is accepted (non-enforcing soft enum) —
              the binary's runtime model set is not a safe closed enum.
            '';
          };
        };
      };
      default = {};
      description = ''
        Typed Claude settings (effortLevel, model) plus freeform passthrough,
        written to ~/.claude/settings.json by upstream. Null typed keys are
        filtered out before reaching upstream.
      '';
    };
```

- [ ] **Step 4: Add the `unpinLaunchEffort` option**

Still in the shared `options = { … }` block (e.g. right after `settings`), add:

```nix
    unpinLaunchEffort = lib.mkOption {
      type = lib.types.attrsOf lib.types.bool;
      default = lib.genAttrs extracted.launchEffortPins (_: true);
      defaultText = lib.literalExpression
        ''lib.genAttrs [ "unpinOpus47LaunchEffort" "unpinOpus48LaunchEffort" ] (_: true)'';
      description = ''
        Per-model "acknowledge launch-default effort" flags merged into
        ~/.claude.json (HM only) so settings.effortLevel is honored instead of
        a newly-shipped model's launch-default effort pin. Keys are
        auto-derived from the packaged binary
        (overlays/claude-code-extracted.json). Set a key false to deliberately
        leave that model pinned.
      '';
    };
```

- [ ] **Step 5: Null-filter the settings on the HM side**

In the HM `config` block, `aiCommon` is already imported. Change the delegation
(line ~237) from the raw inherit to a null-filter:

```nix
            # was: inherit (cfg) settings;
            settings = aiCommon.filterNulls cfg.settings;
```

(The devenv side already does
`aiCommon.filterNulls (removeAttrs cfg.settings …)` — no change needed there.
The `ENABLE_LSP_TOOL` env block remains a separate module-merge contribution and
composes with the filtered settings.)

- [ ] **Step 6: Write the new eval tests (failing first)**

Add to `checks/module-eval.nix` (anywhere in the top-level attrset, near the
other `module-claude-hm-*` tests):

```nix
  # Strict enum: an invalid effortLevel must throw at eval.
  module-claude-hm-effort-level-rejects-invalid = mkTest "claude-hm-effort-level-rejects-invalid" (
    let
      attempt = builtins.tryEval (
        let
          ev = evalHm {
            ai.claude = {
              enable = true;
              settings.effortLevel = "ultra";
            };
          };
        in
          builtins.deepSeq ev.config.ai.claude.settings.effortLevel
          ev.config.ai.claude.settings.effortLevel
      );
    in
      attempt.success == false
  );

  # Valid effortLevel reaches upstream.
  module-claude-hm-effort-level-valid-reaches-upstream = mkTest "claude-hm-effort-level-valid-reaches-upstream" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          settings.effortLevel = "xhigh";
        };
      };
    in
      (result.config.programs.claude-code.settings.effortLevel or null) == "xhigh"
  );

  # Null typed keys are filtered out — upstream never sees effortLevel/model.
  module-claude-hm-null-settings-filtered = mkTest "claude-hm-null-settings-filtered" (
    let
      result = evalHm {ai.claude.enable = true;};
      s = result.config.programs.claude-code.settings or {};
    in
      !(s ? effortLevel) && !(s ? model)
  );

  # Soft-enum model: an arbitrary (unknown) id is accepted and reaches upstream.
  module-claude-hm-model-soft-enum-accepts-arbitrary = mkTest "claude-hm-model-soft-enum-accepts-arbitrary" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          settings.model = "some-future-model";
        };
      };
    in
      (result.config.programs.claude-code.settings.model or null) == "some-future-model"
  );
```

Run them red (the submodule isn't implemented yet only if you write tests before
Steps 2–5; since Steps 2–5 are in the same commit, run them after implementing):

```bash
treefmt packages/claude-code/lib/mkClaude.nix checks/module-eval.nix
nix build .#checks.x86_64-linux.module-claude-hm-effort-level-rejects-invalid
nix build .#checks.x86_64-linux.module-claude-hm-effort-level-valid-reaches-upstream
nix build .#checks.x86_64-linux.module-claude-hm-null-settings-filtered
nix build .#checks.x86_64-linux.module-claude-hm-model-soft-enum-accepts-arbitrary
```

Expected: all PASS.

- [ ] **Step 7: Confirm existing Claude settings tests still pass**

```bash
nix build .#checks.x86_64-linux.module-claude-hm-settings-reach-upstream
nix build .#checks.x86_64-linux.module-claude-devenv-settings-gap-writes-effort-level
nix build .#checks.x86_64-linux.module-claude-devenv-settings-empty-no-gap-file
nix build .#checks.x86_64-linux.module-claude-hm-sets-lsp-env-when-servers-present
```

Expected: all PASS. (`effortLevel = "medium"` is a valid enum value;
`model=null` is filtered; the devenv side already filtered nulls.)

- [ ] **Step 8: Full check + commit**

```bash
git add packages/claude-code/models.json packages/claude-code/lib/mkClaude.nix checks/module-eval.nix
nix flake check
```

```
feat(claude-code): typed effortLevel + model settings submodule
```

---

## Task 5 — WS1: reconcile `unpinLaunchEffort` into `~/.claude.json` at activation

**Goal:** At HM activation, merge `cfg.unpinLaunchEffort` into mutable
`~/.claude.json` via the shared helper (Task 2), so a newly-shipped model's
launch-effort pin is defeated and `settings.effortLevel` is honored. HM-only
(devenv never touches `$HOME`). Always logs the applied count (0 visible).

**Files:**

- Modify: `packages/claude-code/lib/mkClaude.nix` (HM `let` + mkMerge list)
- Modify: `checks/module-eval.nix` (reconciler tests)

- [ ] **Step 1: Import the helper in the Claude HM `let`**

In `mkClaude.nix`'s `hm.config` `let` (next to `aiCommon`/`dirHelpers`), add:

```nix
      helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
```

- [ ] **Step 2: Add the reconciler activation to the HM mkMerge**

Add a new element to the HM `lib.mkMerge [ … ]` list (e.g. right after the
`programs.claude-code = { … }` delegation block):

```nix
        # Reconcile per-model launch-effort unpin flags into ~/.claude.json
        # so settings.effortLevel is honored instead of a newly-shipped
        # model's launch-default pin. HM-only — devenv never touches $HOME
        # (documented category exception). The log line is unconditional so
        # an emptied flag map is visible ("reconciling 0 …"); the merge body
        # is included only when there are flags. Never `exit` here — the
        # block inlines into HM's set -eu activation script.
        (let
          n = builtins.length (builtins.attrNames cfg.unpinLaunchEffort);
        in {
          home.activation.claudeUnpinLaunchEffort =
            lib.hm.dag.entryAfter ["writeBoundary"] (
              ''
                echo "ai.claude: reconciling ${toString n} launch-effort unpin flag(s) into ~/.claude.json"
              ''
              + lib.optionalString (n > 0) (helpers.mkSettingsActivationScript {
                configFile = ".claude.json";
                settingsJson = builtins.toJSON cfg.unpinLaunchEffort;
                jq = "${pkgs.jq}/bin/jq";
                coreutils = pkgs.coreutils;
              })
            );
        })
```

(`~/.claude.json` lives at `$HOME` root; `dirOf ".claude.json"` is `"."`, so the
helper's `mkdir -p "$HOME/."` is a harmless no-op. The `jq -s '.[0] * .[1]'`
merges our flags on top of the existing file, preserving oauth tokens/counters.)

- [ ] **Step 3: Write the reconciler tests**

Add to `checks/module-eval.nix`:

```nix
  # Default reconciler: flags from the committed sidecar are merged into
  # ~/.claude.json through the shared helper.
  module-claude-hm-reconciles-unpin-launch-effort = mkTest "claude-hm-reconciles-unpin-launch-effort" (
    let
      result = evalHm {ai.claude.enable = true;};
      activation = result.config.home.activation.claudeUnpinLaunchEffort or null;
    in
      activation
      != null
      && lib.hasInfix "unpinOpus48LaunchEffort" (activation.text or "")
      && lib.hasInfix ".claude.json" (activation.text or "")
      && lib.hasInfix "jq" (activation.text or "")
  );

  # Emptied flag map: merge body omitted, but the applied-0 log still fires.
  module-claude-hm-unpin-empty-logs-zero = mkTest "claude-hm-unpin-empty-logs-zero" (
    let
      result = evalHm {
        ai.claude.enable = true;
        ai.claude.unpinLaunchEffort = lib.mkForce {};
      };
      activation = result.config.home.activation.claudeUnpinLaunchEffort or null;
    in
      activation
      != null
      && lib.hasInfix "reconciling 0" (activation.text or "")
      && !(lib.hasInfix "unpinOpus48LaunchEffort" (activation.text or ""))
  );

  # A key set false is still written (re-pins that model deliberately).
  module-claude-hm-unpin-false-key-written = mkTest "claude-hm-unpin-false-key-written" (
    let
      result = evalHm {
        ai.claude.enable = true;
        ai.claude.unpinLaunchEffort.unpinOpus48LaunchEffort = false;
      };
      activation = result.config.home.activation.claudeUnpinLaunchEffort or null;
    in
      activation != null && lib.hasInfix "false" (activation.text or "")
  );
```

- [ ] **Step 4: Run the reconciler tests**

```bash
treefmt packages/claude-code/lib/mkClaude.nix checks/module-eval.nix
nix build .#checks.x86_64-linux.module-claude-hm-reconciles-unpin-launch-effort
nix build .#checks.x86_64-linux.module-claude-hm-unpin-empty-logs-zero
nix build .#checks.x86_64-linux.module-claude-hm-unpin-false-key-written
```

Expected: all PASS.

- [ ] **Step 5: Confirm the reconciler does NOT appear on the devenv side**

The reconciler is HM-only by construction (it's in `hm.config`, not
`devenv.config`). Sanity-check no devenv activation/file leaked:

```bash
nix build .#checks.x86_64-linux.module-claude-devenv-settings-empty-no-gap-file
```

Expected: PASS (devenv still writes no `~`-scoped state).

- [ ] **Step 6: Full check + commit**

```bash
git add packages/claude-code/lib/mkClaude.nix checks/module-eval.nix
nix flake check
```

```
feat(claude-code): reconcile unpinLaunchEffort into ~/.claude.json at activation
```

---

## Task 6 — WS2: soft-enum model hint for Kiro `defaultModel`

**Goal:** Give Kiro's `chat.defaultModel` the same non-enforcing soft-enum shape
as Claude's `model` (`either (enum known) str`), curated to the probe-confirmed
dot-notation catalog.

**Files:**

- Create: `packages/kiro-cli/models.json`
- Modify: `packages/kiro-cli/lib/mkKiro.nix` (top `let` + `defaultModel` type)
- Modify: `checks/module-eval.nix` (soft-enum tests)

- [ ] **Step 1: Create the curated Kiro model list (dot notation)**

Create `packages/kiro-cli/models.json` (Kiro uses dot-notation ids; Opus 4.8 is
probe-confirmed available):

```json
["claude-opus-4.8", "claude-sonnet-4.6", "claude-haiku-4.5"]
```

`treefmt` it and `git add packages/kiro-cli/models.json`.

- [ ] **Step 2: Read the list in `mkKiro.nix`**

Wrap the `lib.ai.app.mkAiApp { … }` in a `let` (mirroring Task 4 Step 2):

```nix
{
  lib,
  pkgs,
  ...
}: let
  # Eval-pure read of the committed source list (no IFD).
  knownKiroModels = builtins.fromJSON (builtins.readFile ../models.json);
in
  lib.ai.app.mkAiApp {
    name = "kiro";
    # … rest unchanged …
```

- [ ] **Step 3: Change the `defaultModel` type to a soft-enum**

In the `settings` submodule's `chat` sub-submodule (lines ~76-80), replace the
`defaultModel` option:

```nix
                defaultModel = lib.mkOption {
                  type = lib.types.nullOr
                    (lib.types.either (lib.types.enum knownKiroModels) lib.types.str);
                  default = null;
                  description = ''
                    Default chat model. Known ids
                    (packages/kiro-cli/models.json, dot-notation) autocomplete;
                    any string is accepted (non-enforcing soft enum).
                  '';
                };
```

(`enableThinking` stays `nullOr bool` — Kiro has no per-level thinking enum;
design doc §1.2.)

- [ ] **Step 4: Write the soft-enum tests**

Add to `checks/module-eval.nix`:

```nix
  # Known Kiro model id reaches the cli.json merge.
  module-kiro-hm-default-model-known-accepted = mkTest "kiro-hm-default-model-known-accepted" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          settings.chat.defaultModel = "claude-opus-4.8";
        };
      };
      activation = result.config.home.activation.kiroSettingsMerge or null;
    in
      activation != null && lib.hasInfix "claude-opus-4.8" (activation.text or "")
  );

  # Arbitrary (unknown) id is accepted (str branch of the soft enum).
  module-kiro-hm-default-model-arbitrary-accepted = mkTest "kiro-hm-default-model-arbitrary-accepted" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          settings.chat.defaultModel = "some-future-model";
        };
      };
      activation = result.config.home.activation.kiroSettingsMerge or null;
    in
      activation != null && lib.hasInfix "some-future-model" (activation.text or "")
  );
```

- [ ] **Step 5: Run tests + confirm the existing Kiro merge test still passes**

```bash
treefmt packages/kiro-cli/lib/mkKiro.nix checks/module-eval.nix
nix build .#checks.x86_64-linux.module-kiro-hm-default-model-known-accepted
nix build .#checks.x86_64-linux.module-kiro-hm-default-model-arbitrary-accepted
nix build .#checks.x86_64-linux.module-kiro-hm-writes-settings-activation
```

Expected: all PASS (the last one sets `defaultModel = "claude-sonnet-4"`, which
the `str` branch accepts).

- [ ] **Step 6: Full check + commit**

```bash
git add packages/kiro-cli/models.json packages/kiro-cli/lib/mkKiro.nix checks/module-eval.nix
nix flake check
```

```
feat(kiro-cli): soft-enum model hint for defaultModel
```

---

## Task 7 — WS3: model staleness checks (Claude flake check + devenv task)

**Goal:** Flag drift between the hand-curated model lists and each CLI's live
reality. Claude → pure offline flake check (advisory/warn, rides update). Kiro →
local authed devenv task (stub-guarded). Copilot → manual curation only, noted.

**Files:**

- Create: `checks/model-staleness-claude.nix`
- Modify: `flake.nix:202-212` (register the advisory check)
- Create: `dev/tasks/check.nix`
- Modify: `devenv.nix:300-304` (register the task)

- [ ] **Step 1: Write the advisory Claude staleness check**

Create `checks/model-staleness-claude.nix`:

```nix
# Advisory model-staleness check — compares the curated
# packages/claude-code/models.json against the binary's firstParty:
# registry. ADVISORY: a new id nudges a curation PR; it never fails CI
# (the curated list is intentionally a subset — no deprecated/date-suffixed
# ids). Distinct from checks/claude-code-extracted.nix, which BLOCKS.
{
  lib,
  pkgs,
  self,
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  bin = "${self.packages.${system}.claude-code}/bin/claude";
  committed = ../packages/claude-code/models.json;
in {
  model-staleness-claude = pkgs.runCommand "model-staleness-claude" {} ''
    grep="${pkgs.gnugrep}/bin/grep"
    sed="${pkgs.gnused}/bin/sed"
    jq="${pkgs.jq}/bin/jq"
    sort="${pkgs.coreutils}/bin/sort"
    comm="${pkgs.coreutils}/bin/comm"
    tee="${pkgs.coreutils}/bin/tee"

    binIds=$("$grep" -aoE 'firstParty:"claude-[a-z0-9-]+"' "${bin}" \
      | "$sed" -E 's/^firstParty:"//; s/"$//' | "$sort" -u || true)
    committedIds=$("$jq" -r '.[]' ${committed} | "$sort" -u)
    {
      echo "claude model staleness (advisory):"
      if [ -z "$binIds" ]; then
        echo "  WARNING: no firstParty: ids found — upstream may have changed the registry shape."
      else
        missing=$("$comm" -23 <(printf '%s\n' "$binIds") <(printf '%s\n' "$committedIds") || true)
        if [ -z "$missing" ]; then
          echo "  curated list covers every current binary id (subset by design)."
        else
          echo "  binary exposes ids NOT in packages/claude-code/models.json:"
          printf '    %s\n' $missing
          echo "  curate packages/claude-code/models.json if any are current/non-deprecated."
        fi
      fi
    } | "$tee" $out
  '';
}
```

- [ ] **Step 2: Register the advisory check**

In `flake.nix`'s checks block, add the import + merge entry:

```nix
      formattingCheck = import ./checks/formatting.nix {inherit inputs pkgs self;};
      modelStalenessClaudeCheck = import ./checks/model-staleness-claude.nix {inherit lib pkgs self;};
```

```nix
      bareCommandsCheck // cacheHitParityCheck // claudeExtractedCheck // factoryChecks // formattingCheck // fragmentsChecks // modelStalenessClaudeCheck // moduleChecks // pnpmFetcherParityCheck);
```

- [ ] **Step 3: Verify the advisory check is green**

```bash
git add checks/model-staleness-claude.nix flake.nix
treefmt checks/model-staleness-claude.nix flake.nix
nix build .#checks.x86_64-linux.model-staleness-claude && cat result
```

Expected: builds (exit 0) and prints the advisory report. Because the curated
list is a subset, the report will likely list extra binary ids — that is
expected advisory output, **not** a failure (the check never `exit 1`s on
drift).

- [ ] **Step 4: Write the Kiro/Copilot devenv task**

Create `dev/tasks/check.nix` (matches the bare-command style of
`dev/tasks/generate.nix`; runs in the devenv shell where `kiro-cli`, `jq`, and
coreutils are on PATH):

```nix
# dev/tasks/check.nix — local validation tasks that need network/auth
# and therefore cannot run in the CI sandbox / flake checks.
{
  lib,
  pkgs,
}: let
  bashPreamble = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
  '';
  log = ''log() { echo "==> $*" >&2; }'';
in {
  tasks = {
    "check:model-staleness" = {
      description = "Compare committed model lists against each CLI's live list-models (local, authed)";
      exec = ''
        ${bashPreamble}
        ${log}

        # ── Kiro (needs AWS SSO + network) ──────────────────────────────
        log "Kiro: querying live model catalog"
        kiro_json=$(kiro-cli chat --list-models -f json 2>/dev/null || true)
        if [ -z "$kiro_json" ]; then
          log "Kiro: no output (not authed / offline) — SKIPPED"
        else
          # Stub-guard: the offline degraded payload is auto-only. Treat as
          # not-authed; do NOT report drift (avoids a false positive).
          only_auto=$(printf '%s' "$kiro_json" \
            | jq -r '[.models[].model_name] == ["auto"]' 2>/dev/null || echo false)
          model_ids=$(printf '%s' "$kiro_json" \
            | jq -r '.models[].model_id' 2>/dev/null | sort -u || true)
          if [ "$only_auto" = "true" ] || [ -z "$model_ids" ]; then
            log "Kiro: offline auto-only stub detected — SKIPPED (not a drift)"
          else
            committed=$(jq -r '.[]' packages/kiro-cli/models.json | sort -u)
            missing=$(comm -23 <(printf '%s\n' "$model_ids") <(printf '%s\n' "$committed") || true)
            if [ -z "$missing" ]; then
              log "Kiro: OK — packages/kiro-cli/models.json covers the live catalog"
            else
              log "Kiro: DRIFT — live ids missing from packages/kiro-cli/models.json:"
              printf '    %s\n' $missing >&2
            fi
          fi
        fi

        # ── Copilot ─────────────────────────────────────────────────────
        # No list-models command exists (V8 bytecode SEA). Manual curation
        # only — design doc §5.3. No automated check.
        log "Copilot: no list-models command — manual curation only (skipped)"

        log "Model staleness check complete"
      '';
    };
  };
}
```

- [ ] **Step 5: Register the task in `devenv.nix`**

In the `tasks = let … in …` block (lines ~301-304), add the import and merge:

```nix
  tasks = let
    generateTasks = (import ./dev/tasks/generate.nix {inherit lib;}).tasks;
    checkTasks = (import ./dev/tasks/check.nix {inherit lib pkgs;}).tasks;
  in
    generateTasks
    // checkTasks
    // {
      # … existing inline update:all / build:all tasks unchanged …
```

- [ ] **Step 6: Verify the task is registered and runs**

```bash
git add dev/tasks/check.nix devenv.nix
treefmt dev/tasks/check.nix devenv.nix
devenv tasks list | grep model-staleness
devenv tasks run check:model-staleness
```

Expected: the task is listed; running it prints the Kiro result (OK / DRIFT /
SKIPPED depending on your AWS auth) and the Copilot manual-curation note,
exiting 0. Offline/unauthed must print SKIPPED — **not** a drift/false-positive.

- [ ] **Step 7: Full check + commit**

```bash
nix flake check
```

Expected: passes (the advisory check builds; the devenv task is not a flake
check, so CI does not run the live Kiro query).

```
feat(checks): claude model staleness flake check + check:model-staleness devenv task
```

---

## Cross-task verification (after all 7 commits)

- [ ] **Cold-eval IFD guard.** Confirm no IFD regression — eval must not force a
      build:

  ```bash
  nix eval --json .#packages.x86_64-linux \
    --apply 'ps: builtins.attrNames ps' > /dev/null
  ```

  Expected: succeeds without fetching/building (the new `readFile`s target
  committed source JSON, not derivation outputs).

- [ ] **End-to-end activation smoke (manual, HM consumer).** On a machine with
      the HM module active and `ai.claude.enable = true`:
  - `home-manager switch` (use `-b backup` once if a clobber error appears).
  - `jq '.unpinOpus48LaunchEffort' ~/.claude.json` → `true`.
  - With both pin flags cleared first, a fresh `claude` honors
    `settings.effortLevel` (e.g. `xhigh`); `/effort max` still works for a
    session.

- [ ] **Whole suite.** `nix flake check` green; `treefmt` clean
      (`treefmt --fail-on-change` style: `git diff --exit-code` after a final
      `treefmt`).

---

## Self-Review (author checklist — run after drafting)

**Spec coverage (every workstream → task):**

- WS1 effort-pin reconciliation + typed effort → Tasks 3 (extract+drift), 4
  (typed submodule+null-filter), 5 (reconciler). ✓
- WS2 model soft-enums → Task 4 (Claude), Task 6 (Kiro). Copilot stays freeform
  (design §1.2). ✓
- WS3 staleness → Task 7 (Claude flake check + Kiro/Copilot devenv task). ✓
- WS4 DRY restore → Task 2 (shared helper, all three call sites). ✓
- WS5 docs scrub → Task 1. ✓
- §6 failure checks: non-empty + count==1 baked into `mkClaudeExtract` (enforced
  when the drift check builds `passthru.extracted`); committed-vs-binary
  blocking drift (Task 3); advisory model drift (Task 7); null-filter +
  enum-rejection eval tests (Task 4); applied-count activation log (Task 5). ✓
- §7 parity: reconciliation HM-only documented in-code (Task 5 comment);
  soft-enum is pure typing → parity free; staleness homes intentionally
  asymmetric. ✓

**Type/name consistency:**

- `passthru.extracted` (runCommand) and `vu.mkClaudeExtract` referenced
  consistently in Tasks 3 (overlay) and 3/7 (checks). ✓
- `mkSettingsActivationScript { configFile, settingsJson, jq, coreutils }` —
  identical param set at all four call sites (helper def Task 2; Copilot/Kiro
  Task 2; Claude Task 5). ✓
- `overlays/claude-code-extracted.json` shape `{launchEffortPins, effortLevels}`
  is produced by `mkClaudeExtract`, read by `mkClaude.nix`
  (`extracted.effortLevels`, `extracted.launchEffortPins`), diffed by the drift
  check — consistent. ✓
- `models.json` is array-of-strings in both packages; read via
  `fromJSON (readFile ../models.json)` and `jq -r '.[]'`. ✓

**Placeholder scan:** every code step contains the actual Nix/shell; commands
include expected output; no "TBD"/"add error handling"/"similar to Task N". ✓

**Known risk flagged for execution (not a placeholder — a verification point):**
the update-script integration (Task 3 Step 3 `extraExtract`) runs
`nix build .#claude-code.passthru.extracted` against the dirty-tracked
`sources.json` inside the CI worktree, and relies on the update pipeline staging
`overlays/claude-code-extracted.json` into the per-dependency commit. This
cannot be exercised by `nix flake check`; verify it on the first real
`update/claude-code` PR (the drift check will catch any desync as a hard
failure). If the pipeline does not auto-stage the regenerated file, add an
explicit `git add overlays/claude-code-extracted.json` to the `extraExtract`
snippet.

---

## Execution Handoff

Plan saved to `docs/plans/typed-model-and-thinking-config-implementation.md`
(kept beside its design doc `…-convergence.md`, per project convention which
overrides the skill's default `docs/superpowers/plans/`).

Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task,
   review between tasks, fast iteration. (REQUIRED SUB-SKILL:
   superpowers:subagent-driven-development.)
2. **Inline Execution** — execute tasks in this session with checkpoints.
   (REQUIRED SUB-SKILL: superpowers:executing-plans.)

Note: default to supervisor-worker-verifier with per-task HITL approval; commits
route through the `/stack-*` skills (AGENTS.md "Skill Routing").

---

## Execution status & open items

**Executed 2026-06-18** as a supervisor-worker-verifier run (one worker subagent
per task, supervisor-verified, committed via the `/stack-*` skills). All 7 tasks
landed and the full `nix flake check` is green. The stack was then rebased onto
the latest `origin/refactor/ai-factory-architecture` (which had merged
`update claude-code` to 2.1.181); commits 3–4 were amended to adapt:

- `mkClaudeExtract` is now minifier-variable-agnostic — 2.1.159 emitted the
  effort validator as `effortLevel:y.enum(…)`, 2.1.181 as
  `effortLevel:H.enum(…)`. The grep keys on the `effortLevel:` prefix + the
  level array, not a fixed minifier token.
- The committed sidecar now carries three launch pins (2.1.181 added
  `unpinFable5LaunchEffort` alongside `unpinOpus47/48LaunchEffort`).
- `unpinLaunchEffort.defaultText` is now the symbolic
  `lib.genAttrs extracted.launchEffortPins (_: true)` so it never goes stale as
  the pin set changes.

### Pending MANUAL checkpoints (not runnable in CI / not auto-run)

1. **HM activation smoke** — on a host with the module active and
   `ai.claude.enable = true`: `home-manager switch` (use `-b backup` once if a
   clobber error appears), then confirm
   `jq '.unpinOpus48LaunchEffort' ~/.claude.json` is `true` and that a fresh
   `claude` honors `settings.effortLevel` (e.g. `xhigh`); `/effort max` still
   works for a session.
2. **`devenv tasks run check:model-staleness`** — live Kiro model-catalog query
   (needs AWS SSO + network; offline/unauthed prints SKIPPED, never a drift).
3. **First real `update/claude-code` PR** — verifies the update pipeline's
   `extraExtract` regenerates and stages `overlays/claude-code-extracted.json`
   in the same per-dependency commit (the only step `nix flake check` cannot
   exercise; the blocking drift check hard-fails on any desync, so it is
   safe-by-construction).
