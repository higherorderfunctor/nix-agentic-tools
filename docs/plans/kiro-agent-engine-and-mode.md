# Kiro CLI V3 — typed `agentEngine` + `mode` launch flags

> Status: IMPLEMENTED (T1–T3 + tests) — T4 staleness check deferred (Q2-b).
> Branch: refactor/ai-factory-architecture
> Date: 2026-06-18
>
> Landed: `packages/kiro-cli/engines.json`; `agentEngine` + `mode`
> soft-enum options, `effectiveAgentEngine` (tui⇒v2 default), wrapper
> append, and the `tui`+`v1` assertion in `packages/kiro-cli/lib/mkKiro.nix`;
> 5 eval tests in `checks/module-eval.nix` (all green, no regression).
> Decisions: Q-A=(a) auto-default v2 + assert on v1; Q1=inline mode;
> Q2=defer staleness check; Q3=emit `--agent-engine`, never `--v3`.
> NOT done: commit (user-gated); consumer nixos-config toggle (user-gated).

## Motivation

Kiro CLI 2.8.1 ships an early-access "next generation agent" (V3).
The consumer wants to opt in declaratively, the same way they already
force `--tui` from their nixos-config.

### What the flags actually are (from `kiro-cli chat --help`, 2.8.1)

| Flag                          | Kind  | Meaning                                                                |
| ----------------------------- | ----- | ---------------------------------------------------------------------- |
| `--tui`                       | bool  | "Use the new terminal UI" — UI harness (already typed as `tui`)        |
| `--legacy-ui` / `--classic`   | bool  | old harness                                                            |
| `--agent-engine <v1\|v2\|v3>` | value | agent engine; v2 is default                                            |
| `--v3`                        | bool  | "Launch the next generation Kiro agent" — sugar, ≈ `--agent-engine v3` |
| `--mode <default\|spec>`      | value | V3 sub-mode                                                            |

We expose the **explicit** `--agent-engine` + `--mode` surface (the
typed-enum choice) rather than the `--v3` boolean sugar.

### Validated behavior — kiro-cli 2.8.1 (empirical, this machine)

Probed via `kiro-cli chat <flags> --no-interactive </dev/null` (clap +
app-level conflict checks fire before the input check) and the
interactive path (confirms it's not a `--no-interactive` artifact):

| Combination                            | Result                                                                                                        |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| deprecation markers on `--tui`         | **none** — `--tui` is current ("Use the new terminal UI")                                                     |
| `--tui` **alone** (no engine)          | ❌ `Conflicting options: --tui cannot be used with --agent-engine=v1. Use --agent-engine=v2 or remove --tui.` |
| `--tui --agent-engine v2`              | ✅ clean                                                                                                      |
| `--tui --agent-engine v3`              | ✅ clean                                                                                                      |
| `--tui --v3`                           | ✅ clean (combinable)                                                                                         |
| `--v3` alone                           | ✅ clean (engine v3 implied)                                                                                  |
| `--v3 --agent-engine <e>`              | ❌ clap mutual-exclusion — pick one                                                                           |
| `--mode spec` (alone / v2 / v3 / --v3) | ✅ clean — no engine dependency, no conflict                                                                  |

**Three load-bearing findings:**

1. **`--tui` is NOT deprecated.** It's the new UI; orthogonal to engine.
2. **You can run `--tui` together with v3** (`--tui --v3` or
   `--tui --agent-engine v3`). UI harness × agent engine are independent
   axes — answers the original question: yes, combinable.
3. **⚠️ Bare `--tui` is REJECTED on 2.8.1.** The new TUI refuses the
   implicit/legacy `v1` engine and demands an explicit `--agent-engine`
   of v2 or v3. **The consumer's current forced bare `--tui` therefore
   errors on every launch on 2.8.1** — this is almost certainly the real
   trigger for the question. Fixing `--tui` now _requires_ the engine
   option, independent of whether they want V3.
4. `--v3` and `--agent-engine` are mutually exclusive (clap). The typed
   `agentEngine` enum must emit **`--agent-engine <v>` and never `--v3`**
   to avoid the conflict.

## Where it lives (resolved)

- **Mechanism → this repo.** The wrapper has no generic flag
  passthrough; only `tui` and `trustedMcpTools` are wired. The consumer
  cannot inject a launch flag today.
- **Toggle → consumer nixos-config.** Like `tui = true`, the consumer
  sets `agentEngine = "v3"` / `mode = "spec"`.

## Design

Reuse two existing patterns already in `mkKiro.nix`:

1. **Soft-enum typing** — copy the `defaultModel` shape
   (`nullOr (either (enum known) str)`), known list read eval-pure from
   a committed JSON sidecar. Soft so v4 / a new mode never breaks eval.
2. **Launch-flag delivery** — append to the existing
   `wrapProgram $out/bin/kiro-cli` block, exactly like `--tui`.
   **HM-only**, same acknowledged gap as `tui` (devenv runs the raw
   binary, no wrapper). Documented in the option descriptions.

These are NOT `cli.json` settings — there is no known settings key for
engine/mode; they are `chat` CLI flags only.

3. **`tui ⇒ engine` coupling (new, from validation).** Because bare
   `--tui` errors on v1, the module must guarantee an engine is emitted
   whenever `tui = true`. Chosen handling (Open Q-A below):
   - If `tui = true` and `agentEngine == null` → **auto-emit
     `--agent-engine v2`** (matches the binary's own "Use
     --agent-engine=v2" guidance; transparently un-breaks existing
     `tui = true` consumers).
   - If `tui = true` and `agentEngine == "v1"` → **eval-time assertion**
     fails with the binary's guidance (mirror the runtime rule at
     config-eval time instead of letting the launch error).
   - Always emit `--agent-engine`, never `--v3` (mutual exclusion).

## Tasks

### T1 — `engines.json` sidecar (SSOT)

- Create `packages/kiro-cli/engines.json` = `["v1","v2","v3"]`.
  Mirrors `models.json`; one source feeds both the enum and the
  (optional) staleness check. DRY.
- `mode` values (`default`, `spec`) are low-churn → inline list in
  `mkKiro.nix` rather than a sidecar. (Open Q1: sidecar instead?)

### T2 — typed options in `mkKiro.nix`

- `knownKiroEngines = builtins.fromJSON (builtins.readFile ../engines.json);`
  next to `knownKiroModels`.
- New options under `options` (top level, alongside `tui` — these are
  flags, not `settings.*` keys):
  ```nix
  agentEngine = lib.mkOption {
    type = lib.types.nullOr
      (lib.types.either (lib.types.enum knownKiroEngines) lib.types.str);
    default = null;
    description = "Agent engine launch flag (--agent-engine). Known ids
      (packages/kiro-cli/engines.json) autocomplete; any string accepted
      (non-enforcing soft enum). HM only — devenv doesn't wrap the binary.";
  };
  mode = lib.mkOption {
    type = lib.types.nullOr
      (lib.types.either (lib.types.enum ["default" "spec"]) lib.types.str);
    default = null;
    description = "V3 agent mode launch flag (--mode). HM only.";
  };
  ```

### T3 — wrapper delivery (HM)

- Add `hasEngine = cfg.agentEngine != null;` / `hasMode = cfg.mode != null;`.
- Extend `needsWrapper` and the `kiro-cli` wrapProgram gate to include them.
- Append inside the existing `wrapProgram $out/bin/kiro-cli` block:
  ```nix
  ${lib.optionalString hasEngine ''--append-flags "--agent-engine ${cfg.agentEngine}"''}
  ${lib.optionalString hasMode ''--append-flags "--mode ${cfg.mode}"''}
  ```
  (Matches the existing `--tui` append idiom — `--append-flags` inserts
  after `"$@"`; clap parses options after the positional, same as `--tui`.)

### T4 — advisory staleness check (OPTIONAL / Open Q2)

- `checks/engine-staleness-kiro.nix`, mirroring `model-staleness-claude.nix`:
  parse `--agent-engine` possible-values, compare to `engines.json`,
  **warn never fail**.
- Wrinkle: model-staleness greps the binary statically (`firstParty:`
  literals). Engine tokens (`v1`/`v2`/`v3`) are too generic to grep, so
  this check must _run_ `kiro-cli chat --help` in the sandbox. That's
  fine on linux-x64; the darwin `.dmg` binary can't run in a linux
  sandbox → gate the check to the host platform only (the claude check
  is already per-`system`). Decision below.
- Register in `flake.nix` next to `modelStalenessClaudeCheck`; add a
  `check:engine-staleness` devenv task mirroring `check:model-staleness`.

### T5 — docs / fragments / propagation

- Update any kiro-cli wrapper fragment with a `Last verified:` marker
  that documents the flag surface (grep `packages/kiro-cli/docs/`,
  `fragments/`). Mandatory per AGENTS.md if the shape changed.
- README / option-reference surfaces that list kiro options.
- `treefmt` every touched file; `nix flake check`.

## Open questions for review

- **Q-A (new, primary) — `tui ⇒ engine` coupling handling.** Since bare
  `--tui` errors on 2.8.1:
  - (a) **Auto-default to `--agent-engine v2` when `tui = true` &
    engine unset** + assert on explicit `v1`. Transparently fixes the
    current broken setup. **← my lean.**
  - (b) Hard assertion only — force the consumer to set `agentEngine`
    explicitly whenever `tui = true` (no magic default).
  - (c) Do nothing — emit only what's set, let the binary error.
- **Q1 — `mode` source** — inline `["default" "spec"]`, or commit
  `modes.json` for symmetry with engines? (Lean inline: 2 stable values.)
- **Q2 — staleness check now or later?** The one piece needing the
  binary run + platform gating.
  - (a) Ship T4 now, linux-only advisory check.
  - (b) Defer T4; rely on soft-enum + manual curation (engines change
    slowly; v4 isn't out). **← my lean**, given "early release"
    volatility and the cross-platform run wrinkle.
- **Q3 — RESOLVED by validation.** Do **not** expose the `--v3` boolean;
  it's mutually exclusive with `--agent-engine`. `agentEngine = "v3"` is
  the surface; the wrapper emits `--agent-engine v3` only.
- **Q4 — devenv parity** — accept HM-only (mirrors `tui`), documented?
  A devenv story needs devenv to wrap/alias the binary — larger change,
  out of scope.

## Verification

- `nix flake check`
- `nix build .#kiro-cli` then inspect the HM-wrapped binary's
  `--append-flags` (build a throwaway HM eval or read the generated
  wrapper) to confirm `--agent-engine v3 --mode spec` land.
- Manually: `kiro-cli --tui --agent-engine v3 --mode spec` behaves as V3.
