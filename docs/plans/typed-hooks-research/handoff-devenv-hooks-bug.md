# Handoff — fix the Claude devenv hook-emission latent bug

Standalone steering prompt for a session to fix the latent type-mismatch bug
found during the typed-hooks assessment. Preserved here so it isn't lost if the
parallel factory session doesn't pick it up as related. Context:
`docs/plans/typed-hooks-across-clis-assessment.md` §3.1, §5, §7, §8.

---

```
Fix a latent type-mismatch bug in the ai.* factory's Claude devenv hook emission.

CONTEXT (read first): docs/plans/typed-hooks-across-clis-assessment.md §3.1, §5 (esp. §5 "⚠
Latent bug"), §7, §8. A typed-hooks refactor is PLANNED there — keep this fix SURGICAL and
aligned with §8's direction; do not build the full typed surface here.

THE BUG (packages/claude-code/lib/mkClaude.nix, devenv projection):
  :507  claude.code.hooks = (cfg.settings.hooks or {}) // cfg.hooks;
- cfg.hooks (= ai.claude.hooks) is `attrsOf lines` — hook SCRIPT BODIES keyed by filename.
- cfg.settings.hooks is freeform event-nested JSON, e.g. { PreToolUse = [ {matcher; hooks=[…];} ]; }.
- devenv's REAL claude.code.hooks type is `attrsOf hookSubmodule` where hookSubmodule ≈
  { enable?; name?; hookType(enum ~17 events); matcher?; command; } (per assessment research,
  reading cachix/devenv src/modules/integrations/claude.nix — VERIFY this against the actual
  devenv module in your nix store before relying on it).
- So the `//` result matches NEITHER arm of that type: a script string isn't a {hookType;command}
  record, and `PreToolUse = [...]` treats an EVENT NAME as a hook NAME whose value is a list.

WHY IT'S HIDDEN: checks/module-eval.nix:112 stubs `claude.code = attrsOf anything` (and :67/:73-74
collapse `programs.claude-code` the same way, per the comment at :67), so `nix flake check` never
type-checks this against devenv's real schema.

STEP 1 — REPRODUCE before fixing (systematic-debugging):
  a) Read devenv's actual claude.code.hooks option type from the store; confirm the hookSubmodule
     shape + the ~17-event hookType enum.
  b) Construct a MINIMAL real devenv eval (not the module-eval stub) that sets a Claude hook via
     ai.claude.hooks and/or ai.claude.settings.hooks, and show it errors against the real type
     (single `--max-jobs 1` eval; no parallel fan-out). If NO current consumer sets Claude hooks
     in devenv, confirm it's LATENT (never triggered today) and say so — that changes urgency,
     not correctness.
  Do not proceed to a fix until you've either reproduced the error or confirmed-latent with evidence.

STEP 2 — FIX (recommended direction, matches assessment §5/§8):
  Bypass devenv's claude.code.hooks submodule entirely; emit the two concerns SEPARATELY, mirroring
  the HM side so HM↔devenv stay byte-parity:
    - event-wiring (cfg.settings.hooks event map) → files.".claude/settings.json".json.hooks = <map>,
      deep-merged with the existing gapSettings write (mkClaude.nix:511-517); remove "hooks" from
      upstreamOwnedSettingsKeys (:472) so it flows through, or write it explicitly.
    - script bodies (cfg.hooks, keyed by filename) → files.".claude/hooks/<name>".text = <body>
      (devenv has no programs.claude-code.hooks equivalent; write the files directly, as HM's
      upstream module does).
  Alternatives to weigh: (b) construct proper devenv hookSubmodule records and let devenv group them
  (lossy — command-only, no timeout/http/prompt/agent); (c) only narrow the module-eval stub. Pick
  per §5's reasoning; (a) is preferred for fidelity + parity + forward-compat.

  While here, check the composition sub-issue (§5/§7): devenv's own `claude.code.hooks.git-hooks-run`
  default ALSO writes settings.hooks.PostToolUse, and pkgs.formats.json merge REPLACES lists — so two
  writers of settings.json.hooks.PostToolUse clobber. Ensure our write UNIONS with it (or is ordered
  so neither is lost); add a golden assertion that the merged result contains BOTH.

STEP 3 — VERIFY: add/extend a module-eval golden test proving ai.claude.hooks + settings.hooks lower
to the correct settings.json.hooks JSON + .claude/hooks/<name> files on BOTH HM and devenv (byte-
parity), and that the devenv result conforms to devenv's REAL claude.code type (import it, or assert
the emitted shape). Do not leave `attrsOf anything` as the only guard for this path.

GUARDRAILS:
- HM↔devenv parity is non-negotiable; don't regress existing ai.claude.hooks / settings.hooks consumers.
- No parallel subagent fan-out / nix-fast-build / flake-check fan-out — it OOMs (openmemory MCP per
  subagent). Single `--max-jobs 1` builds/evals only.
- nixos-config changes and user tests are HITL — don't touch nixos-config or run a live switch without
  explicit approval. Don't commit/push unless asked.
- COORDINATION: another session created UNTRACKED files under docs/plans/typed-hooks-across-clis-
  assessment.md and docs/plans/typed-hooks-research/ — do not modify, move, or `git clean` them.
```
