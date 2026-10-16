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
    map (p: p.drvPath) (lib.filter (p: p.name == "kiro-cli-wrapped") packages);

  # Exactly one wrapper on each side, and they must DIFFER (the unlock forked).
  soleFork = a: b:
    builtins.length a == 1 && builtins.length b == 1 && builtins.head a != builtins.head b;

  # Exactly one wrapper on each side, and they must MATCH (dedupe collapsed).
  soleSame = a: b:
    builtins.length a == 1 && builtins.length b == 1 && builtins.head a == builtins.head b;

  # Logical steering content before formatting; delivery is asserted separately.
  kiroSteeringContent = evaluated: let
    prefix = "${evaluated.config.ai.kiro.configDir}/steering/";
  in
    lib.mapAttrs' (target: entry:
      lib.nameValuePair (lib.removePrefix prefix target) entry.content)
    (lib.filterAttrs (target: _entry: lib.hasPrefix prefix target) evaluated.config.ai.kiro._generatedFiles);
  # Read the live layer-1 value before the generated tree renders it.
  kiroCliSettings = ev:
    ev.config.ai.kiro.files2."${ev.config.ai.kiro.configDir}/settings/cli.json".content.value;
in {
  inherit idempotentFlags kiroCliSettings kiroSteeringContent kiroWrappedDrvs renderKiroSecrets renderedMcpJson soleFork soleSame;
}
