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
# The four v3 lifecycle hooks (one `.kiro/hooks/kiro-memory.json` envelope):
#   Stop             → kiro-memory-distiller  (per-turn, debounced distill of new turns)
#   SessionStart     → kiro-memory-flush      (flush prior sessions' dropped tails)
#   Manual           → kiro-memory-distiller  (user `/remember`; forces an immediate distill, D3/D33)
#   UserPromptSubmit → kiro-memory-recall     (per-turn READ: inject the recent tier +
#                                              a best-effort openmemory archive query, D30/5b)
# All bins ship from overlays/kiro-memory-distiller.nix (STAGE 2, `pkgs.ai.*`).
#
# Backend wiring (STAGE 5b): the distiller's write path (`openmemory-mem add`) and the
# recall read path (`openmemory-mem query`) shell out to the `openmemory-mem` SDK helper
# by bare name. That helper ships as a bin of `pkgs.ai.mcpServers.openmemory-mcp`; this
# wiring layer (NOT the backend-agnostic distiller package) puts its bin dir on every
# wrapper's PATH and threads the `OM_*` Postgres-connection env. The `OM_PG_PASSWORD`
# secret is NEVER baked into the store — it is cat from `omPgPasswordFile` at runtime
# (SOPS-pattern). With no `omEnv`/`omPgPasswordFile` (the default), the backend calls
# best-effort-fail and the hooks fall back to the file buffer alone.
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
  # OM_* openmemory backend-connection env baked into every wrapper (the SDK helper
  # reads OM_* at import to reach the same Postgres the daemon uses — e.g.
  # { OM_METADATA_BACKEND = "postgres"; OM_PG_HOST = "127.0.0.1"; OM_PG_DB = "openmemory";
  #   OM_USER_ID = "dev-no-auth"; … }). Consumers should derive this from the SAME source
  # as the daemon (openmemory-mcp settingsToEnv) so the hook and daemon stay schema-lockstep
  # (Q11). MUST NOT include OM_PG_PASSWORD — that is a secret; use omPgPasswordFile.
  omEnv ? {},
  # Runtime path (a STRING, not a Nix path — a Nix path would copy the secret into the
  # world-readable store) to a file holding the Postgres password. If set, every wrapper
  # cats it into OM_PG_PASSWORD at runtime (SOPS-pattern). null → no password exported.
  omPgPasswordFile ? null,
  # Per-hook command timeout in seconds; kiro waits up to this on Stop.
  timeout ? 30,
}: let
  distiller = pkgs.ai.kiro-memory-distiller;
  distillBin = lib.getExe' distiller "kiro-memory-distiller";
  flushBin = lib.getExe' distiller "kiro-memory-flush";
  recallBin = lib.getExe' distiller "kiro-memory-recall";

  # openmemory-mem (the backend add/query helper) ships as a bin of openmemory-mcp;
  # its bin dir on the wrapper PATH lights up the distiller's best-effort backend calls
  # (write `add`, read `query`). Bound HERE, not in the distiller package, so that stays
  # backend-agnostic (a future markdown-only backend reuses it unchanged).
  omBinPath = lib.makeBinPath [pkgs.ai.mcpServers.openmemory-mcp];

  # HOME guarantee (S9/D25). The `:?` guard ALWAYS runs, so an unset OR empty HOME
  # fails loud before any write — covering a null `home` (rely on ambient), an
  # empty string, and a stripped ambient HOME even when a path was baked. A
  # non-empty `home` is additionally baked; an empty string is NOT (`export
  # HOME=''` would defeat the guard, since the distiller keeps an empty string).
  homeBlock = lib.concatStringsSep "\n" (
    lib.optional (home != null && home != "") "export HOME=${lib.escapeShellArg home}"
    ++ ['': "''${HOME:?kiro-memory: HOME unset — refusing to write cwd-relative memory}"'']
  );

  # Baked env for every wrapper: KIRO_MEMORY_* tuning + OM_* backend connection,
  # merged and sorted for deterministic output. The Postgres password is NEVER in
  # here (see omPgPasswordFile); guard against a caller smuggling it into omEnv.
  bakedEnv = env // omEnv;
  envLines =
    lib.concatStringsSep "\n"
    (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg (toString v)}")
      bakedEnv);

  # Runtime secret read (SOPS-pattern): cat the password file into OM_PG_PASSWORD on
  # every invocation. Best-effort (`|| :`) so a missing/rotating secret degrades to the
  # file-buffer tier rather than crashing the hook. Absolute cat path (nix-standards).
  passwordLine =
    lib.optionalString (omPgPasswordFile != null)
    ''export OM_PG_PASSWORD="$(${pkgs.coreutils}/bin/cat ${lib.escapeShellArg omPgPasswordFile} 2>/dev/null || :)"'';

  # One wrapper per role. Absolute store paths only (nix-standards): the sole
  # external command is the distiller bin (absolute via getExe') plus a runtime cat
  # (absolute) for the secret; the openmemory-mem helper resolves off the prepended
  # PATH. Everything else is a bash builtin. Strict mode per repo convention.
  #
  # `force` bakes `KIRO_MEMORY_FORCE=1` (which distiller main() honors, bypassing
  # the debounce) — the Manual `/remember` wrapper is exactly the Stop wrapper plus
  # force, so a user asking to remember is never silently no-op'd by the debounce
  # after a recent Stop (D3/D33). Placed AFTER envLines so it wins over a
  # consumer-supplied `KIRO_MEMORY_FORCE` in `env`; the per-turn Stop stays
  # debounced (force=false → the line renders empty).
  mkWrapper = {
    suffix,
    bin,
    force ? false,
  }:
    pkgs.writeShellScript "kiro-memory-${suffix}" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      export PATH=${omBinPath}:"$PATH"
      ${homeBlock}
      ${lib.optionalString (bakedEnv != {}) envLines}
      ${lib.optionalString force "export KIRO_MEMORY_FORCE=1"}
      ${passwordLine}
      exec ${bin} "$@"
    '';

  stopWrapper = mkWrapper {
    suffix = "stop";
    bin = distillBin;
  };
  flushWrapper = mkWrapper {
    suffix = "flush";
    bin = flushBin;
  };
  manualWrapper = mkWrapper {
    suffix = "manual";
    bin = distillBin;
    force = true;
  };
  recallWrapper = mkWrapper {
    suffix = "recall";
    bin = recallBin;
  };

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
        description = "Deterministic user-triggered distill (/remember): forces an immediate distill past the debounce.";
      })
      (mkHook {
        name = "kiro-memory-recall";
        trigger = "UserPromptSubmit";
        command = "${recallWrapper}";
        description = "Inject recent working context + project-memory archive hits (read-only, per-turn).";
      })
    ];
  };

  # Static steering anchor (B1): frames HOW the auto-maintained memory works and
  # the project_id convention. Immutable store symlink → no live content here;
  # the live buffer lives in ~/.kiro-memory and is maintained by the hooks.
  anchorText = ''
    # Persistent project memory (auto-maintained)

    This project has deterministic, harness-driven memory — you do NOT have to
    remember to call a tool for it to work. Hook-driven channels keep it current
    and surface it to you automatically:

    - **Recent working context** is distilled from each turn and rolled into
      `~/.kiro-memory/<project>/{now,recent,archive}.md` by the `Stop` and
      `SessionStart` hooks, then re-injected before each of your prompts by the
      `UserPromptSubmit` hook (alongside a best-effort semantic query of the
      `openmemory` archive). Treat it as read-only; do not hand-edit it.
    - **Project scope.** Memory is keyed on the *canonical repo root* shared
      across all git worktrees of this repo, so every worktree sees the same
      project memory. Put cross-cutting facts (preferences, coding standards)
      in `openmemory`'s `system_global` scope, not the per-project buffer.

    You can force an immediate distill at any point with the `Manual`
    `/remember` hook. Everything else is automatic.
  '';
in
  # A secret in EITHER env or omEnv is baked (bakedEnv = env // omEnv) into the
  # world-readable store; route it through omPgPasswordFile (runtime cat) instead.
  # Guard the merged set, not just omEnv, and fail loud rather than leak.
  assert lib.assertMsg (!(bakedEnv ? OM_PG_PASSWORD))
  "kiroAutoMemory: OM_PG_PASSWORD must not be in env/omEnv (it would bake into the store); use omPgPasswordFile for the runtime secret."; {
    hooks."kiro-memory" = builtins.toJSON hookEnvelope;
    rules."kiro-auto-memory" = {
      paths = null; # null → kiro `inclusion: always`
      description = "How this project's auto-maintained memory works.";
      text = anchorText;
    };
  }
