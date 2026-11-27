# A declared `toolPolicy` reaches each runtime's native per-tool surface in
# that runtime's spelling, on both backends, and a runtime or backend without
# a lossless surface warns instead of dropping it.
{
  lib,
  harness,
  ...
}: let
  inherit (harness) checkRows claudeMcpServers claudeSettings evalDevenv evalHm mkTest rejectsChange setEnable;
  inherit (import ../../packages/chatgpt-codex/checks/helpers.nix {inherit lib;}) hmCodexSettings;
  url = "https://example.test/mcp";
  toolPolicy = {
    a = "auto";
    b = "prompt";
    c = "disabled";
  };
  backends = {
    devenv = evalDevenv;
    hm = evalHm;
  };
  evalServer = backend: runtime: server: extra:
    backends.${backend} (lib.foldl' lib.recursiveUpdate {} [
      (setEnable runtime true)
      {ai.mcpServers.probe = {inherit url;} // server;}
      extra
    ]);
  evalPolicy = backend: runtime: server:
    evalServer backend runtime (lib.recursiveUpdate {inherit toolPolicy;} server) {};
  # The one line a gap emits for the probe's policy, if any.
  policyWarnings = config:
    builtins.filter (lib.hasPrefix "ai.mcpServers.probe.toolPolicy is set but") config.warnings;
  claudeRules = {
    devenv = {
      allow = ["mcp__probe__a"];
      ask = ["mcp__probe__b"];
      deny = ["mcp__probe__c"];
    };
    hm = {
      allow = ["mcp__plugin_hm_probe__a"];
      ask = ["mcp__plugin_hm_probe__b"];
      deny = ["mcp__plugin_hm_probe__c"];
    };
  };
  codexSettings = backend: evaluated:
    if backend == "hm"
    then hmCodexSettings evaluated
    else evaluated.config.ai.codex.files.".codex/config.toml".content.value;
  kiroRule = rule: {inherit (rule) capability effect match;};
  perBackend = name: test:
    lib.mapAttrs' (backend: _: let
      label = "mcp-tool-policy-${name}-${backend}";
    in
      lib.nameValuePair "module-${label}" (mkTest label (test backend)))
    backends;
in {
  checks = lib.mkMerge [
    {
      module-mcp-tool-policy-modes = mkTest "mcp-tool-policy-modes" (checkRows "MCP tool policy modes" {
        "toolPolicy rejects an unknown approval mode" = rejectsChange (policy:
          (evalHm {
            ai.mcpServers.probe = {
              inherit url;
              toolPolicy = policy;
            };
          }).config.ai.mcpServers.probe.toolPolicy) {
          valid = toolPolicy;
          invalid = toolPolicy // {b = "approve";};
          expected = toolPolicy;
        };
      });
    }
    # Claude: allow / ask / deny rules named the way Claude names the tool,
    # and nothing policy-shaped in the server entry itself. A proxied server's
    # lowered client entry keeps the policy against the loopback entry.
    (perBackend "claude" (backend: let
      check = server: expectedUrl: let
        evaluated = evalPolicy backend "claude" server;
      in
        (claudeSettings evaluated).permissions
        == claudeRules.${backend}
        && (claudeMcpServers backend evaluated).probe
        == {
          type = "http";
          url = expectedUrl;
        };
    in
      checkRows "Claude policy delivery (${backend})" {
        "direct server keeps its URL and exact permission rules" = check {} url;
        "proxied server uses the loopback URL without losing permission rules" = check {
          proxy = {
            enable = true;
            port = 9555;
          };
        } "http://127.0.0.1:9555/";
      }))
    # Codex: approve / prompt per tool and a disabled_tools list; a native
    # `codex.tools` entry still wins for its tool.
    (perBackend "codex" (backend:
      (codexSettings backend (evalPolicy backend "codex" {
        codex.tools.d.approvalMode = "prompt";
        toolPolicy.d = "auto";
      }))
      .mcp_servers
      .probe
      == {
        disabled_tools = ["c"];
        tools = {
          a.approval_mode = "approve";
          b.approval_mode = "prompt";
          d.approval_mode = "prompt";
        };
        inherit url;
      }))
    {
      # No permission surface exists on devenv. The gap must name every tool,
      # not just the disabled tool exercised by ai-warnings-delivery.
      module-mcp-tool-policy-kiro-devenv = mkTest "mcp-tool-policy-kiro-devenv" (let
        warnings = policyWarnings (evalPolicy "devenv" "kiro" {}).config;
      in
        checkRows "Kiro policy delivery (devenv)" {
          "one warning lists auto, prompt and disabled tools" =
            builtins.length warnings
            == 1
            && lib.hasSuffix "keep Kiro's default: a, b, c.)" (builtins.head warnings);
        });
      module-mcp-tool-policy-kiro-hm = mkTest "mcp-tool-policy-kiro-hm" (let
        home = (evalPolicy "hm" "kiro" {}).config;
        existing = {
          capability = "mcp";
          effect = "deny";
          match = ["existing/write"];
        };
        defaults =
          (evalServer "hm" "kiro" {} {
            ai.kiro = {
              cli.trustedMcpTools = lib.mkDefault ["@existing/read"];
              permissions = lib.mkDefault [existing];
            };
          }).config.ai.kiro;
      in
        checkRows "Kiro policy delivery (hm)" {
          "auto becomes tool trust" = home.ai.kiro.cli.trustedMcpTools == ["@probe/a"];
          # With no shared policy, the consumer's mkDefault definitions survive.
          "no policy preserves consumer trust and rules" =
            defaults.cli.trustedMcpTools
            == ["@existing/read"]
            && map kiroRule defaults.permissions == [existing];
          # These rules reach Kiro only through permissions.yaml.
          "prompt and disabled become ask and deny rules" =
            map kiroRule home.ai.kiro.permissions
            == [
              {
                capability = "mcp";
                effect = "ask";
                match = ["probe/b"];
              }
              {
                capability = "mcp";
                effect = "deny";
                match = ["probe/c"];
              }
            ];
          "supported policy writes permissions.yaml without a gap warning" =
            home.home.file ? ".kiro/settings/permissions.yaml"
            && policyWarnings home == [];
        });
    }
    # Kimchi has no surface for the policy: one warning and an ordinary MCP
    # server entry, without a new permissions file or rule.
    (perBackend "kimchi" (backend: let
      evaluated = evalPolicy backend "kimchi" {};
      files = evaluated.config.ai.files;
      # Home Manager owns the user file even when no rules are declared;
      # devenv only claims a project permissions file for a declaration.
      path =
        if backend == "hm"
        then ".config/kimchi/harness"
        else ".kimchi";
    in
      checkRows "Kimchi policy delivery (${backend})" {
        "MCP entry contains no policy fields" =
          files."${path}/mcp.json".content.value
          == {
            mcpServers.probe = {
              type = "http";
              inherit url;
            };
          };
        "no policy permissions are written" =
          if backend == "hm"
          then files."${path}/permissions.json".content.value == {}
          else !(files ? "${path}/permissions.json");
        "unsupported policy warns once" = builtins.length (policyWarnings evaluated.config) == 1;
      }))
  ];
}
