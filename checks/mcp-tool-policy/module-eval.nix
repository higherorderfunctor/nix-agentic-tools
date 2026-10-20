# A declared `toolPolicy` reaches each runtime's native per-tool surface in
# that runtime's spelling, on both backends, and a runtime or backend without
# a lossless surface warns instead of dropping it.
{
  lib,
  harness,
  ...
}: let
  inherit (harness) claudeMcpServers claudeSettings evalDevenv evalHm mkTest setEnable;
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
  evalWith = backend: runtime: extra:
    backends.${backend} (lib.foldl' lib.recursiveUpdate {} [
      (setEnable runtime true)
      {ai.mcpServers.probe = {inherit toolPolicy url;};}
      extra
    ]);
  # The one line a gap emits for the probe's policy, if any.
  policyWarnings = evaluated:
    builtins.filter (lib.hasPrefix "ai.mcpServers.probe.toolPolicy is set but") evaluated.config.warnings;
  claudeRules = backend: let
    prefix =
      if backend == "hm"
      then "mcp__plugin_hm_probe__"
      else "mcp__probe__";
  in {
    allow = ["${prefix}a"];
    ask = ["${prefix}b"];
    deny = ["${prefix}c"];
  };
  codexSettings = backend: evaluated:
    if backend == "hm"
    then hmCodexSettings evaluated
    else evaluated.config.ai.codex.files.".codex/config.toml".content.value;
  kiroRule = rule: {inherit (rule) capability effect match;};
  # The repository supports Kiro's v3 engine only; v2 is untested.
  kiroCase = backend: let
    evaluated = evalWith backend "kiro" {ai.kiro.cli.v3 = true;};
    inherit (evaluated.config.ai) kiro;
    rulesDelivered = backend == "hm";
    warnings = policyWarnings evaluated;
  in
    builtins.elem "@probe/a" kiro.cli.trustedMcpTools
    && map kiroRule kiro.permissions
    == lib.optionals rulesDelivered [
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
    ]
    && (
      if rulesDelivered
      then warnings == []
      else
        builtins.length warnings
        == 1
        && lib.hasSuffix "keep Kiro's default: b, c.)" (builtins.head warnings)
    );
  # A consumer's own lower-priority trust and rules, with no policy declared.
  kiroExistingRule = {
    capability = "mcp";
    effect = "deny";
    match = ["existing/write"];
  };
  perBackend = name: test:
    lib.mapAttrs' (backend: _:
      lib.nameValuePair "module-mcp-tool-policy-${name}-${backend}"
      (mkTest "mcp-tool-policy-${name}-${backend}" (test backend)))
    backends;
in {
  checks = lib.mkMerge [
    # Claude: allow / ask / deny rules named the way Claude names the tool,
    # and nothing policy-shaped in the server entry itself.
    (perBackend "claude" (backend: let
      evaluated = evalWith backend "claude" {};
    in
      (claudeSettings evaluated).permissions
      == claudeRules backend
      && (claudeMcpServers backend evaluated).probe
      == {
        type = "http";
        inherit url;
      }))
    # Codex: approve / prompt per tool and a disabled_tools list; a native
    # `codex.tools` entry still wins for its tool.
    (perBackend "codex" (backend:
      (codexSettings backend (evalWith backend "codex" {
        ai.mcpServers.probe = {
          toolPolicy.d = "auto";
          codex.tools.d.approvalMode = "prompt";
        };
      }))
      .mcp_servers
      .probe
      == {
        inherit url;
        disabled_tools = ["c"];
        tools = {
          a.approval_mode = "approve";
          b.approval_mode = "prompt";
          d.approval_mode = "prompt";
        };
      }))
    # Kiro: `auto` is a trusted tool everywhere; ask and deny rules exist only
    # where they reach permissions.yaml (Home Manager with v3); whatever a
    # backend cannot carry is named in one warning.
    (perBackend "kiro" (backend:
      kiroCase backend
      && (backend == "devenv" || (evalWith backend "kiro" {ai.kiro.cli.v3 = true;}).config.home.file ? ".kiro/settings/permissions.yaml")))
    # Kiro with no policy: a consumer's mkDefault trust and rules survive.
    (perBackend "kiro-defaults" (backend: let
      inherit
        ((backends.${backend} (lib.recursiveUpdate (setEnable "kiro" true) {
            ai = {
              kiro = {
                cli.trustedMcpTools = lib.mkDefault ["@existing/read"];
                permissions = lib.mkDefault [kiroExistingRule];
              };
              mcpServers.probe = {inherit url;};
            };
          }))
          .config
          .ai)
        kiro
        ;
    in
      kiro.cli.trustedMcpTools
      == ["@existing/read"]
      && map kiroRule kiro.permissions == [kiroExistingRule]))
    # Kimchi has no surface for the policy: one warning, nothing rendered.
    (perBackend "kimchi" (backend: builtins.length (policyWarnings (evalWith backend "kimchi" {})) == 1))
    # A proxied server's lowered client entry keeps its policy, so the runtime
    # still renders it against the loopback entry.
    (perBackend "proxy" (backend: let
      evaluated = evalWith backend "claude" {
        ai.mcpServers.probe.proxy = {
          enable = true;
          port = 9555;
        };
      };
    in
      (claudeSettings evaluated).permissions
      == claudeRules backend
      && (claudeMcpServers backend evaluated).probe.url == "http://127.0.0.1:9555/"))
  ];
}
