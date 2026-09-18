{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) mcpLib;

  # Generic idempotent-flag helper shared with mkKiro's wrapper (lib/idempotentFlags.nix).
  idempotentFlags = import ../../../lib/idempotentFlags.nix {inherit lib;};
  # Kiro mcp-secret preprocessor + the rendered mcp.json body the module
  # feeds into its materializer renderer (mkMcpJsonScript). Tests
  # assert placeholder content via `renderedMcpJson` and template-store-
  # path parity between the two backends.
  inherit (import ../lib/mcpSecrets.nix {inherit lib;}) renderKiroSecrets;
  renderedMcpJson = servers:
    builtins.toJSON {
      mcpServers = lib.mapAttrs (name: mcpLib.renderServer pkgs name) (renderKiroSecrets servers).servers;
    };

  # Helpers for the rollout-unlock tests. They exist to keep `lib.head` off an
  # unguarded filtered list: if the wrapper were renamed or dropped, `head`
  # throws an eval error, which surfaces as an infrastructure failure with a
  # stack trace rather than as this test failing. Worse, a comparison between
  # two silently-wrong singletons can pass VACUOUSLY. Asserting the match count
  # as part of the returned boolean fixes both.
  kiroWrappedDrvs = packages:
    map (p: p.drvPath) (lib.filter (p: (p.name or "") == "kiro-cli-wrapped") packages);

  # Exactly one wrapper on each side, and they must DIFFER (the unlock forked).
  soleFork = a: b:
    builtins.length a == 1 && builtins.length b == 1 && builtins.head a != builtins.head b;

  # Exactly one wrapper on each side, and they must MATCH (dedupe collapsed).
  soleSame = a: b:
    builtins.length a == 1 && builtins.length b == 1 && builtins.head a == builtins.head b;

  # ── Kiro file/materializer helpers ────────────────────────────────
  # Steering now lives in the common runtime file map. Strip its native prefix
  # in tests that care about the logical steering filenames rather than the
  # backend target.
  #
  # `matLib = aiBase.materialize;` used to sit here. Its only consumer was the
  # kiro auto-memory suite, removed with that subsystem on 2026-09-01, and
  # deadnix caught it as an unused binding.
  kiroSteeringFiles = evaluated: let
    prefix = "${evaluated.config.ai.kiro.configDir}/steering/";
  in
    lib.mapAttrs' (target: entry:
      lib.nameValuePair (lib.removePrefix prefix target) entry)
    (lib.filterAttrs (target: _entry: lib.hasPrefix prefix target) evaluated.config.ai.kiro.files);
  hmRetirementScript = ev: (ev.config.home.activation."retire-materialize-kiro-steering" or {}).text or "";
  dvTaskExec = ev: ((ev.config.tasks or {})."ai:kiro:retire-steering-copies" or {}).exec or "";
  # Kiro HOOKS ride the same materializer (copy-only; v3 drops symlinked
  # hooks), so they get the same accessor trio against the hooks slug.
  hmHookPruneScript = ev: (ev.config.home.activation."materialize-kiro-hooks-prune" or {}).text or "";
  hmHookWriteScript = ev: (ev.config.home.activation."materialize-kiro-hooks-write" or {}).text or "";
  dvHookTaskExec = ev: ((ev.config.tasks or {})."ai:kiro:materialize-hooks" or {}).exec or "";
  hmMcpPruneScript = ev: (ev.config.home.activation."materialize-kiro-settings-prune" or {}).text or "";
  hmMcpWriteScript = ev: (ev.config.home.activation.kiroMcpJson or {}).text or "";
  dvMcpTaskExec = ev: ((ev.config.tasks or {})."ai:kiro:materialize-mcp" or {}).exec or "";
  # Extract the heredoc body a copy writer embeds for <name> — the
  # #433 heredoc-extraction idiom (see module-kiro-hooks-typed-
  # colocation). The per-script EOF marker is content-hash-derived, so
  # recover it from the `nat_mat_write '<name>' …<<'MARKER'` call line;
  # the script embeds store paths, whose context the split helpers
  # reject, so strip it (byte content is unchanged).
  matHeredocBody = script: name: let
    t = builtins.unsafeDiscardStringContext script;
    parts = lib.splitString "${lib.escapeShellArg name} \"$nat_mat_prev\" ${lib.escapeShellArg "0444"} <<'" t;
  in
    if builtins.length parts < 2
    then null
    else let
      afterCall = builtins.elemAt parts 1;
      marker = builtins.head (lib.splitString "'\n" afterCall);
      body = lib.removePrefix "${marker}'\n" afterCall;
    in
      builtins.head (lib.splitString "\n${marker}\n" body);
in {
  inherit dvHookTaskExec dvMcpTaskExec dvTaskExec hmHookPruneScript hmHookWriteScript hmMcpPruneScript hmMcpWriteScript hmRetirementScript idempotentFlags kiroSteeringFiles kiroWrappedDrvs matHeredocBody renderKiroSecrets renderedMcpJson soleFork soleSame;
}
