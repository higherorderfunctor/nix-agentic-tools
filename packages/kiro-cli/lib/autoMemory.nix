# kiro-cli auto-memory wiring — STAGE 3 of docs/plans/kiro-cli-auto-memory.md.
#
# Produces reusable *values* for the existing `ai.kiro.hooks` / `ai.kiro.rules`
# options — it does NOT add a new module axis (B5: parity is structural, the
# hooks/rules ride the same HM↔devenv fanout every other kiro surface uses). A
# consumer opts in by splicing the results into those options:
#
#   let mem = lib.ai.apps.kiroAutoMemory {
#     inherit pkgs;
#     home = config.home.homeDirectory;   # HM: bake the real HOME (see below)
#   };
#   in {
#     ai.kiro.hooks = mem.hooks;   # attrsOf (lines|path) → .kiro/hooks/<name>.json
#     ai.kiro.rules = mem.rules;   # ai-common ruleModule → .kiro/steering/<name>.md
#   }
#
# The three v3 lifecycle hooks (one `.kiro/hooks/kiro-memory.json` envelope):
#   Stop         → kiro-memory-distiller  (per-turn, debounced distill of new turns)
#   SessionStart → kiro-memory-flush      (flush prior sessions' dropped tails)
#   Manual       → kiro-memory-distiller  (deterministic user `/remember` fallback, D3)
# Both bins ship from overlays/kiro-memory-distiller.nix (STAGE 2, `pkgs.ai.*`).
#
# HOME is load-bearing (S9 STATE / D25): the distiller derives
# sessionsDir/memoryDir from `process.env.HOME` (resolveCliEnv); an unset OR
# EMPTY HOME resolves both to cwd-relative `.kiro/sessions` + `.kiro-memory` and
# silently loses memory (exit 0 — the distiller's `?? ""` keeps an empty string).
# Every hook wrapper therefore ALWAYS runs a fail-loud `:?` guard on HOME (which
# trips on unset AND empty), and additionally bakes a supplied NON-EMPTY absolute
# path. An empty-string `home` is treated exactly like null — never baked, always
# guarded — so a public-API caller cannot re-introduce the cwd-relative loss.
#
# Synchronous, not backgrounded (D8 chose synchronous; D27 reaffirms it over
# B3's later `nohup … &` note): the STAGE-3 distiller is file-IO-only +
# debounced + sub-second, so kiro's Stop `timeout` wait is negligible and a
# store-path background fork would only add fragility. Revisit when the STAGE-5
# openmemory SDK adds a network write.
{
  lib,
  pkgs,
  # Absolute HOME baked into every hook wrapper. HM consumers pass
  # `config.home.homeDirectory`; devenv consumers may pass their home too. null
  # OR an empty string means "do not bake" — the wrapper's always-on guard then
  # hard-fails on an unset/empty ambient HOME instead of writing cwd-relative
  # memory.
  home ? null,
  # Optional KIRO_MEMORY_* overrides exported into every wrapper (e.g.
  # { KIRO_MEMORY_DIR = "/data/kiro-memory"; }). Names are passed through raw.
  env ? {},
  # Per-hook command timeout in seconds; kiro waits up to this on Stop.
  timeout ? 30,
}: let
  distiller = pkgs.ai.kiro-memory-distiller;
  distillBin = lib.getExe' distiller "kiro-memory-distiller";
  flushBin = lib.getExe' distiller "kiro-memory-flush";

  # HOME guarantee (S9/D25). The `:?` guard ALWAYS runs, so an unset OR empty HOME
  # fails loud before any write — covering a null `home` (rely on ambient), an
  # empty string, and a stripped ambient HOME even when a path was baked. A
  # non-empty `home` is additionally baked; an empty string is NOT (`export
  # HOME=''` would defeat the guard, since the distiller keeps an empty string).
  homeBlock = lib.concatStringsSep "\n" (
    lib.optional (home != null && home != "") "export HOME=${lib.escapeShellArg home}"
    ++ ['': "''${HOME:?kiro-memory: HOME unset — refusing to write cwd-relative memory}"'']
  );

  # Optional KIRO_MEMORY_* overrides, sorted for deterministic output.
  envLines =
    lib.concatStringsSep "\n"
    (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg (toString v)}")
      env);

  # One wrapper per role. Absolute store paths only (nix-standards): the sole
  # external command is the distiller bin (absolute via getExe'); everything
  # else is a bash builtin. Strict mode per repo convention.
  mkWrapper = suffix: bin:
    pkgs.writeShellScript "kiro-memory-${suffix}" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${homeBlock}
      ${lib.optionalString (env != {}) envLines}
      exec ${bin} "$@"
    '';

  stopWrapper = mkWrapper "stop" distillBin;
  flushWrapper = mkWrapper "flush" flushBin;
  manualWrapper = mkWrapper "manual" distillBin;

  mkHook = {
    name,
    trigger,
    command,
    description,
  }: {
    inherit name description trigger timeout;
    enabled = true;
    action = {
      type = "command";
      inherit command;
    };
  };

  # v3 standalone hook file: a single `{ version, hooks:[…] }` envelope carrying
  # all three lifecycle hooks (the documented schema supports multiple hooks per
  # file — mkKiro.nix:292-298).
  hookEnvelope = {
    version = "v1";
    hooks = [
      (mkHook {
        name = "kiro-memory-distill";
        trigger = "Stop";
        command = "${stopWrapper}";
        description = "Distill this session's new turns into ~/.kiro-memory (debounced, per-turn).";
      })
      (mkHook {
        name = "kiro-memory-flush";
        trigger = "SessionStart";
        command = "${flushWrapper}";
        description = "Flush prior sessions' dropped tails at startup.";
      })
      (mkHook {
        name = "kiro-memory-remember";
        trigger = "Manual";
        command = "${manualWrapper}";
        description = "Deterministic user-triggered distill fallback (/remember).";
      })
    ];
  };

  # Static steering anchor (B1): frames HOW the auto-maintained memory works and
  # the project_id convention. Immutable store symlink → no live content here;
  # the live buffer lives in ~/.kiro-memory and is maintained by the hooks.
  anchorText = ''
    # Persistent project memory (auto-maintained)

    This project has deterministic, harness-driven memory — you do NOT have to
    remember to call a tool for it to work. Two hook-driven channels keep it
    current with no action from you:

    - **Recent working context** is distilled from each turn and rolled into
      `~/.kiro-memory/<project>/{now,recent,archive}.md` by the `Stop` and
      `SessionStart` hooks. Treat it as read-only; do not hand-edit it.
    - **Project scope.** Memory is keyed on the *canonical repo root* shared
      across all git worktrees of this repo, so every worktree sees the same
      project memory. Put cross-cutting facts (preferences, coding standards)
      in `openmemory`'s `system_global` scope, not the per-project buffer.

    You can force an immediate distill at any point with the `Manual`
    `/remember` hook. Everything else is automatic.
  '';
in {
  hooks."kiro-memory" = builtins.toJSON hookEnvelope;
  rules."kiro-auto-memory" = {
    paths = null; # null → kiro `inclusion: always`
    description = "How this project's auto-maintained memory works.";
    text = anchorText;
  };
}
