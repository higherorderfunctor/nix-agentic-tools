{
  # Where this backend keeps semble's cache. Both backends answer; only a
  # backend that MOVES the cache off semble's own default has to tell semble
  # about it (see `relocatesCache`).
  cacheLocation,
  installPackage,
  # True when `cacheLocation` is a relocation rather than semble's default.
  # Relocating means semble must be told, and the only honest place to put
  # that is the process that reads it. This module does not write the shell
  # environment on either backend: devenv's `env` attrset would export the
  # value into the project shell, handing it to the developer's own session
  # and every other process running there, not just semble.
  relocatesCache ? false,
}: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.semble;
  contentScope = import ../lib/contentScope.nix {inherit lib;};
  records = import ../lib/integrations.nix;
  runtimes = ["claude" "codex" "kiro"];

  # Runtimes whose NAMED AGENT FILES can carry their own `mcpServers` map, so a
  # server can be attached to one agent without the root session seeing it.
  #
  # Kiro alone. Its v3 agent schema carries `mcpServers` per agent, and
  # `includeMcpJson` defaults false so the agent does not also inherit the
  # global pool — a seal in both directions. Claude and Copilot can restrict
  # WHICH tools an agent may call but have no per-agent server definition, so
  # the server would still have to live in the root pool; Copilot goes further
  # and takes one process-wide `--additional-mcp-config`. Codex has neither an
  # agent tool allowlist nor a verified per-agent server layer.
  isolationCapableRuntimes = ["kiro"];

  # Unchanged, and deliberately polymorphic over both `enable` flavours: a
  # nullable `enable` falls back to `semble.enable`, while an opt-in plain bool
  # is never null and so answers for itself.
  featureEnabled = feature:
    if feature.enable != null
    then feature.enable
    else cfg.enable;
  featureRuntimes = feature:
    if feature.runtimes != null
    then feature.runtimes
    else cfg.runtimes;
  selected = runtime: feature:
    featureEnabled feature && lib.elem runtime (featureRuntimes feature);
  featureActive = feature:
    featureEnabled feature && featureRuntimes feature != [];

  cliInstructions = cfg.instructions.cli;

  # DEFINING the server and REGISTERING it with the root session are separate.
  # `rootExposure` null inherits `mcp.enable`, which makes the split invisible
  # to every configuration that does not ask for it: the resolved value is then
  # exactly the old behaviour.
  rootExposed =
    if cfg.mcp.rootExposure != null
    then cfg.mcp.rootExposure
    else featureEnabled cfg.mcp;

  mcpRuntimes = lib.filter (runtime: selected runtime cfg.mcp) runtimes;
  subagentRuntimes = lib.filter (runtime: selected runtime cfg.subagent) runtimes;

  codexSelected = lib.any (feature: selected "codex" feature) [
    cliInstructions
    cfg.mcp
    cfg.subagent
  ];
  mkDefaultRecursive = lib.mapAttrsRecursive (_path: lib.mkDefault);

  cacheDir = cacheLocation {inherit config lib;};

  # A relocating backend relocates UNCONDITIONALLY. The intent is a
  # project-local cache, full stop — nothing about it is Codex-specific.
  #
  # It read otherwise until 2026-08-10 only because the `SEMBLE_CACHE_LOCATION`
  # write happened to live inside the codex-cache hook, which is gated on
  # `codexSelected`. The cache therefore moved depending on whether CODEX was
  # enabled: semble for Claude alone got the XDG default, the same project with
  # Codex on got the project-local one. That was an artifact of where the write
  # sat, and the operator confirmed the project-local cache was always the
  # point; Codex merely inherited the write path by being co-located with it.
  #
  # Granting Codex the writable root DOES stay gated on `codexSelected` below.
  # That gate is real: it is about Codex's sandbox, not about where semble
  # keeps its index.

  # Wrapped once, for every entry point, so `semble` and `semble-mcp` cannot
  # disagree about where the cache lives — and so the MCP server needs no
  # `env` block of its own, since its command already carries the setting.
  semblePackage =
    if !relocatesCache
    then cfg.package
    else
      pkgs.symlinkJoin {
        # Named after what it wraps, so a `semble.package` override stays
        # OBSERVABLE once the package is no longer installed bare. A fixed
        # name would make the override untestable — the wrapped derivation
        # would look identical whatever went into it.
        name = "${lib.getName cfg.package}-wrapped";
        paths = [cfg.package];
        nativeBuildInputs = [pkgs.makeWrapper];
        postBuild = ''
          for bin in "$out"/bin/*; do
            wrapProgram "$bin" \
              --set SEMBLE_CACHE_LOCATION ${lib.escapeShellArg cacheDir}
          done
        '';
      };

  mcpEntry = {
    args = contentScope.toArgs cfg.mcp.content;
    command = "${semblePackage}/bin/semble-mcp";
    type = "stdio";
  };

  # `semble.subagent.interface` values are exactly the keys of the record set,
  # so this is a lookup rather than a branch.
  interfaceRecords = records.${cfg.subagent.interface};

  # An MCP-backed Kiro agent gets its OWN copy of the server precisely when the
  # root session is not getting one. With root exposure on there is nothing to
  # isolate: `tools = ["@semble"]` already selects that server's tools out of
  # the global pool, and a second definition would be a copy that could drift.
  # `includeMcpJson` is written explicitly rather than left to Kiro's default,
  # because the whole point here is that the agent must NOT pick up the rest of
  # the global pool.
  agentScopedMcp = runtime:
    lib.optionalAttrs
    (cfg.subagent.interface == "mcp" && !rootExposed && lib.elem runtime isolationCapableRuntimes)
    {
      includeMcpJson = false;
      mcpServers.semble = mcpEntry;
    };

  agentRecord = runtime:
    if runtime == "kiro"
    then interfaceRecords.kiroAgent // agentScopedMcp runtime
    else interfaceRecords.semanticAgent;

  runtimeConfig = runtime: let
    instruction =
      if runtime == "kiro"
      then records.kiroInstruction
      else records.instruction;
  in
    lib.mkMerge [
      (lib.mkIf (selected runtime cliInstructions) {
        ai.${runtime}.instructions = [instruction];
      })
      (lib.mkIf (selected runtime cfg.mcp && rootExposed) {
        ai.${runtime}.mcpServers.semble = mkDefaultRecursive mcpEntry;
      })
      (lib.mkIf (selected runtime cfg.subagent) {
        # Both records are now typed attrsets (Kiro's shape differs from the
        # portable semantic one, but neither is pre-rendered), so the same
        # per-leaf mkDefault applies to each.
        ai.${runtime}.agents.semble-search = mkDefaultRecursive (agentRecord runtime);
      })
    ];

  # Lowered to `assertions` rather than `throw` so the MESSAGE is inspectable:
  # `nix flake check` asserts on the text, not merely on the failure. The same
  # strings reach `throw` on the `mkSemble` path, which never evaluates a
  # module's config and would silently discard an assertions block.
  assertions =
    map (message: {
      assertion = false;
      inherit message;
    })
    (contentScope.errors cfg.mcp.content)
    ++ lib.optional (featureEnabled cfg.subagent && cfg.subagent.interface == "mcp") {
      assertion = lib.all (runtime: selected runtime cfg.mcp) subagentRuntimes;
      message = ''
        semble.subagent.interface = "mcp" gives the named agent a prompt that
        calls `mcp__semble__search` and `mcp__semble__find_related`, but no
        Semble MCP server is configured for ${
          lib.concatStringsSep ", " (lib.filter (runtime: !(selected runtime cfg.mcp)) subagentRuntimes)
        }. Enable `semble.mcp` for the same runtimes, or use
        `semble.subagent.interface = "cli"`.
      '';
    }
    ++ lib.optionals (featureEnabled cfg.mcp && !rootExposed) [
      {
        assertion = lib.all (runtime: lib.elem runtime isolationCapableRuntimes) mcpRuntimes;
        message = ''
          semble.mcp.rootExposure = false keeps the Semble MCP server out of the
          root session, which only works on a runtime whose agent files carry
          their own `mcpServers` map: ${lib.concatStringsSep ", " isolationCapableRuntimes}.
          ${
            lib.concatStringsSep ", " (lib.filter (runtime: !(lib.elem runtime isolationCapableRuntimes)) mcpRuntimes)
          } cannot attach a server to one agent, so the server would have to be
          registered for the whole session. Drop those runtimes from
          `semble.mcp.runtimes`, or leave `rootExposure` unset.
        '';
      }
      {
        assertion = cfg.subagent.interface == "mcp" && lib.all (runtime: selected runtime cfg.subagent) mcpRuntimes;
        message = ''
          semble.mcp.rootExposure = false defines a Semble MCP server that only
          a named MCP-backed agent can reach, but no such agent is configured
          for ${lib.concatStringsSep ", " mcpRuntimes}. Set
          `semble.subagent.enable = true` with
          `semble.subagent.interface = "mcp"` for the same runtimes, or the
          server is started for nothing.
        '';
      }
    ];
in {
  imports = [(import ./options.nix {inherit lib pkgs;})];

  config = lib.mkMerge (
    [
      {inherit assertions;}
      (lib.mkIf (
          featureActive cliInstructions
          || featureActive cfg.mcp
          || featureActive cfg.subagent
        )
        (installPackage semblePackage))
      # Uniform across backends now that the location is a plain value rather
      # than a round-trip through the shell environment.
      (lib.mkIf codexSelected {
        ai.codex.settings._integration_writable_roots = lib.mkAfter [cacheDir];
      })
    ]
    ++ map runtimeConfig runtimes
  );
}
