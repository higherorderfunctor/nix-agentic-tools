# A declared `toolPolicy` reaches each runtime's native per-tool surface in
# that runtime's spelling, on both backends, and a runtime or backend without
# a lossless surface warns instead of dropping it.
{
  harness,
  lib,
  pkgs,
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
  kiroPermissionsPath = ".kiro/settings/permissions.yaml";
  deliversKiroRules = config: rules: let
    kiro = config.ai.kiro;
    # The delivered file points into a generated tree. Compare its staged
    # YAML input against fixed rules without building that tree during eval.
    stagedSource = kiro._generatedFiles.${kiroPermissionsPath}.content.source;
    # Reuse the serializer and file name for the store path comparison; the
    # rules are the independent expectation.
    expectedSource = (pkgs.formats.yaml {}).generate "kiro-permissions.yaml" {inherit rules;};
  in
    (config.home.file.${kiroPermissionsPath}.source or "")
    == "${kiro._generatedTree}/${kiroPermissionsPath}"
    && toString stagedSource == toString expectedSource;
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
        "the shared enum rejects Codex approval spelling as a portable mode" = rejectsChange (policy:
          (evalHm {
            ai.mcpServers.probe = {
              inherit url;
              toolPolicy = policy;
            };
          }).config.ai.mcpServers.probe.toolPolicy) {
          expected = toolPolicy;
          invalid = toolPolicy // {b = "approve";};
          valid = toolPolicy;
        };
      });
    }
    # Claude: allow / ask / deny rules named the way Claude names the tool,
    # and nothing policy-shaped in the server entry itself. A proxied server's
    # lowered client entry keeps the policy against the loopback entry.
    (perBackend "claude" (backend: let
      evaluated = evalPolicy backend "claude" {
        proxy = {
          enable = true;
          port = 9555;
        };
      };
    in
      checkRows "Claude policy delivery (${backend})" {
        "loopback lowering must not drop or rename the proxied server permissions" =
          (claudeSettings evaluated).permissions
          == claudeRules.${backend}
          && (claudeMcpServers backend evaluated).probe
          == {
            type = "http";
            url = "http://127.0.0.1:9555/";
          };
      }))
    # Codex: approve / prompt per tool and a disabled_tools list; a native
    # `codex.tools` entry still wins for its tool.
    {
      module-mcp-tool-policy-codex-hm = mkTest "mcp-tool-policy-codex-hm" (let
        settings = hmCodexSettings (evalPolicy "hm" "codex" {
          codex.tools.d.approvalMode = "prompt";
          toolPolicy.d = "auto";
        });
        entry = settings.mcp_servers.probe;
      in
        checkRows "Codex policy delivery (hm)" {
          "only a, b and d get approval modes, with native prompt overriding d" =
            entry.tools
            == {
              a.approval_mode = "approve";
              b.approval_mode = "prompt";
              d.approval_mode = "prompt";
            };
          "only shared disabled tool c is placed in disabled_tools" = entry.disabled_tools == ["c"];
          "portable policy does not leak into the native server entry" =
            builtins.removeAttrs entry ["disabled_tools" "tools"] == {inherit url;};
        });
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
          }).config;
      in
        checkRows "Kiro policy delivery (hm)" {
          # Without shared policy, an empty definition must not mask the
          # consumer's mkDefault trust or rules.
          "no policy preserves consumer allow and deny rules in permissions.yaml" = deliversKiroRules defaults [
            {
              capability = "mcp";
              effect = "deny";
              match = ["existing/write"];
            }
            {
              capability = "mcp";
              effect = "allow";
              match = ["existing/read"];
            }
          ];
          # Kiro reads the delivered YAML, not the intermediate module options.
          "shared policies reach permissions.yaml as tool-specific ask, deny and allow rules" = deliversKiroRules home [
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
            {
              capability = "mcp";
              effect = "allow";
              match = ["probe/a"];
            }
          ];
          "supported shared policy does not produce a delivery-gap warning" = policyWarnings home == [];
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
      checkRows "Kimchi policy delivery (${backend})" (
        {
          "unsupported tool modes must not create Kimchi permission rules" =
            if backend == "hm"
            then files."${path}/permissions.json".content.value == {}
            else !(files ? "${path}/permissions.json");
        }
        # Both backends use the same HTTP payload renderer; test it once.
        // lib.optionalAttrs (backend == "devenv") {
          "HTTP MCP entry contains no policy fields" =
            files."${path}/mcp.json".content.value
            == {
              mcpServers.probe = {
                type = "http";
                inherit url;
              };
            };
        }
        # ai-warnings-delivery covers the devenv stdio gap; keep the HM witness
        # for HTTP because the gap itself does not distinguish transports.
        // lib.optionalAttrs (backend == "hm") {
          "unsupported HTTP policy emits exactly one Kimchi delivery warning" =
            policyWarnings evaluated.config
            == ["ai.mcpServers.probe.toolPolicy is set but hm does not deliver it to kimchi (reason: Kimchi's permissions.json has allow and deny lists but no ask list, and the pinned source establishes no rule spelling for an MCP tool, so the policy is not rendered and every tool keeps Kimchi's default.)"];
        }
      )))
  ];
}
