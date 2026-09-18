{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) mcpLib ownPlan;

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
    map (p: p.drvPath) (lib.filter (p: p.name == "kiro-cli-wrapped") packages);

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
  requireBody = path: ev: let
    label = "Kiro check requires config.${lib.showOption path}";
    body = lib.attrByPath path (throw "${label}: attribute is missing") ev.config;
  in
    if builtins.isString body && builtins.match "[[:space:]]*" body == null
    then body
    else throw "${label}: script body is empty or not a string";

  dvHookTaskExec = requireBody ["tasks" "ai:kiro:materialize-hooks" "exec"];
  # A plan is DATA, so the units, their modes, the ledger and the target
  # directory are all readable here — an `own` body is one command and names
  # none of them. `harness.ownPlan` throws on an absent writer, so a renamed
  # entry fails the check rather than satisfying it with an empty plan.
  planTarget = path: plan: let
    hits = lib.filter (target: target.path == path) plan.targets;
  in
    if lib.length hits == 1
    then lib.head hits
    else throw "Kiro check requires exactly one own target for '${path}', found ${toString (lib.length hits)}";
  hookTargetOf = entry: ev: planTarget "${ev.config.ai.kiro.configDir}/hooks" (ownPlan "kiro" entry ev);
  hmHookTarget = hookTargetOf "materialize-kiro-hooks-write";
  dvHookTarget = hookTargetOf "ai:kiro:materialize-hooks";
  # mcp.json's two targets by ROLE: the directory that owns the whole file
  # under `overwrite`, and the document whose leaves it owns under `merge`.
  # Both live in ONE bundle, so both come out of one plan and a check can read
  # the mode, the render command and the ledger of either.
  mcpDirOf = entry: ev: planTarget "${ev.config.ai.kiro.configDir}/settings" (ownPlan "kiro" entry ev);
  mcpDocOf = entry: ev: planTarget "${ev.config.ai.kiro.configDir}/settings/mcp.json" (ownPlan "kiro" entry ev);
  hmMcpDirTarget = mcpDirOf "kiroMcpJson";
  hmMcpDocTarget = mcpDocOf "kiroMcpJson";
  dvMcpDirTarget = mcpDirOf "ai:kiro:materialize-mcp";
  dvMcpDocTarget = mcpDocOf "ai:kiro:materialize-mcp";
  # The `--plan` argument out of an emitted body. `own` passes exactly one, so
  # this is the IDENTITY of the plan a phase applies: two entries that resolve
  # to the same store path cannot disagree about what is owned, which is what
  # the HM prune/write pair needs. The quotes are optional on purpose —
  # `lib.escapeShellArg` leaves a plain store path unquoted — so strip them if
  # they are there. The body embeds store paths, whose context the split
  # helpers reject, so discard it; the bytes are unchanged.
  ownPlanArg = body: let
    parts = lib.splitString "--plan " (builtins.unsafeDiscardStringContext body);
    unquote = token: lib.removeSuffix "'" (lib.removePrefix "'" token);
  in
    if lib.length parts != 2
    then throw "Kiro check requires exactly one --plan argument in an own body"
    else unquote (builtins.head (lib.splitString " " (builtins.elemAt parts 1)));
  dvMcpTaskExec = requireBody ["tasks" "ai:kiro:materialize-mcp" "exec"];
  dvTaskExec = requireBody ["tasks" "ai:kiro:retire-steering-copies" "exec"];
  hmHookPruneScript = requireBody ["home" "activation" "materialize-kiro-hooks-prune" "text"];
  hmHookWriteScript = requireBody ["home" "activation" "materialize-kiro-hooks-write" "text"];
  hmMcpPruneScript = requireBody ["home" "activation" "materialize-kiro-settings-prune" "text"];
  hmMcpWriteScript = requireBody ["home" "activation" "kiroMcpJson" "text"];
  hmRetirementScript = requireBody ["home" "activation" "retire-materialize-kiro-steering" "text"];
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
    then throw "Kiro check requires materializer heredoc for ${name}: write call is missing"
    else let
      afterCall = builtins.elemAt parts 1;
      marker = builtins.head (lib.splitString "'\n" afterCall);
      body = lib.removePrefix "${marker}'\n" afterCall;
    in
      builtins.head (lib.splitString "\n${marker}\n" body);
in {
  inherit dvHookTarget dvHookTaskExec dvMcpDirTarget dvMcpDocTarget dvMcpTaskExec dvTaskExec hmHookPruneScript hmHookTarget hmHookWriteScript hmMcpDirTarget hmMcpDocTarget hmMcpPruneScript hmMcpWriteScript hmRetirementScript idempotentFlags kiroSteeringFiles kiroWrappedDrvs matHeredocBody ownPlanArg renderKiroSecrets renderedMcpJson soleFork soleSame;
}
