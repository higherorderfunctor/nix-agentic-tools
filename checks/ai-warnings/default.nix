{
  harness,
  lib,
  pkgs,
  ...
}: let
  policy = import ../../config/ai-delivery.nix {inherit lib;};
  evaluate = mode: config:
    ((
        if mode == "hm"
        then harness.evalHm config
        else harness.evalDevenv config
      ).extendModules {
        modules = [
          {
            options.warnings = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
            };
          }
        ];
      }).config.warnings;
  contains = needle: messages: lib.any (lib.hasInfix needle) messages;
  sample = {
    agents.probe = {
      description = "probe";
      instructions = "probe";
    };
    context.text = "probe";
    environmentVariables.PROBE = "value";
    hooks.PreToolUse = [{hooks = [{command = "true";}];}];
    lspServers.probe = {command = "probe";};
    mcpServers.probe.command = "probe";
    permissions = [
      {
        capability = "shell";
        effect = "allow";
      }
    ];
    rules.probe.text = "probe";
    settings.model = "probe";
    skills.probe = ../../packages/claude-code/checks/fixtures/claude-skills/skill-a;
  };
  # Every absent or inert primary row gets a populated request and an empty
  # control through the actual factory. Unsupported runtime options use root.
  gaps = lib.filter (row: row.primitive == "notApplicable" || row ? deliveryGap) policy.rows;
  rowCase = row: let
    path =
      if row.surface == "settings"
      then ["ai" row.ecosystem "nativeSettings"]
      else if row.surface == "permissions"
      then ["ai" row.ecosystem "permissions"]
      else ["ai" row.surface];
    applicable = row.surface != "permissions" || row.ecosystem == "kiro";
    enabled = {ai.${row.ecosystem}.enable = true;};
    messages = evaluate row.mode (lib.recursiveUpdate enabled (lib.setAttrByPath path sample.${row.surface}));
    empty = evaluate row.mode enabled;
    needle = lib.concatStringsSep "." path;
  in
    !applicable
    || (contains needle messages
      && contains (row.deliveryGap or row.reason) messages
      && !contains needle empty);
  cases =
    [
      {
        runtime = "kiro";
        path = ["ai" "kiro" "trustedMcpTools"];
        value = ["@probe"];
      }
      {
        runtime = "copilot";
        path = ["ai" "copilot" "context"];
        value.text = "probe";
        mode = "hm";
      }
      {
        runtime = "copilot";
        path = ["ai" "copilot" "rules"];
        value.probe.text = "probe";
        mode = "hm";
      }
      {
        runtime = "kiro";
        path = ["ai" "agents"];
        value = sample.agents;
      }
      {
        runtime = "kiro";
        path = ["ai" "hooks"];
        value = sample.hooks;
      }
      {
        runtime = "kimchi";
        path = ["ai" "shell"];
        value = pkgs.bash;
      }
      {
        runtime = "copilot";
        path = ["ai" "shell"];
        value = pkgs.bash;
      }
      {
        runtime = "codex";
        path = ["ai" "agents" "probe"];
        value = sample.agents.probe // {tools = ["Read"];};
        suffix = ".tools";
      }
      {
        runtime = "kiro";
        path = ["ai" "kiro" "lspServers" "probe"];
        value = {
          command = "probe";
          extensions = ["nix"];
        };
        suffix = ".extensions";
      }
      {
        runtime = "claude";
        path = ["ai" "claude" "mcpServers" "probe"];
        value = {
          url = "https://example.invalid";
          args = ["lost"];
        };
        suffix = ".args";
      }
      {
        runtime = "claude";
        path = ["ai" "claude" "mcpServers" "probe"];
        value = {
          command = "probe";
          settings.lost = true;
        };
        suffix = ".settings";
      }
    ]
    ++ lib.concatMap (http:
      map (field: {
        runtime = "claude";
        path = ["ai" "claude" "mcpServers" "probe"];
        value =
          (
            if http
            then {url = "https://example.invalid";}
            else {command = "probe";}
          )
          // {
            ${field} =
              {
                args = ["probe"];
                command = "probe";
                env.PROBE = "";
                headers.Authorization = "";
                package = pkgs.hello;
                settings.probe = true;
                timeout = 1;
              }.${
                field
              };
          };
        suffix = ".${field}";
      }) (
        if http
        then ["args" "command" "env" "package" "settings"]
        else ["headers" "settings" "timeout"]
      )) [false true]
    ++ map (surface: {
      runtime = "claude";
      path = ["ai" "claude" surface];
      value =
        if surface == "unpinLaunchEffort"
        then {probe = true;}
        else if surface == "outputStyles"
        then {probe = "probe";}
        else {probe = pkgs.emptyDirectory;};
    }) ["marketplaces" "outputStyles" "plugins" "unpinLaunchEffort"]
    ++ [
      {
        runtime = "claude";
        path = ["ai" "claude" "agentsDir"];
        value = ../../packages/claude-code/checks/fixtures/claude-agents;
      }
      {
        runtime = "claude";
        path = ["ai" "claude" "nativeSettings" "mcpServers"];
        value.probe.command = "probe";
      }
      {
        runtime = "kimchi";
        path = ["ai" "kimchi" "harnessSettings"];
        value.resources.probe = true;
      }
      {
        runtime = "kiro";
        path = ["ai" "kiro" "rules" "probe"];
        value = {
          text = "probe";
          inclusion = "manual";
        };
        suffix = ".inclusion";
      }
      {
        runtime = "kiro";
        path = ["ai" "kiro" "hooks" "probe"];
        value = {
          trigger = "UserPromptSubmit";
          action = {
            type = "agent";
            prompt = "probe";
          };
          timeout = 1;
        };
        suffix = ".timeout";
      }
      {
        runtime = "kiro";
        path = ["ai" "kiro" "hooks" "probe"];
        value = {
          trigger = "UserPromptSubmit";
          action = {
            type = "agent";
            prompt = "probe";
            command = "true";
          };
        };
        suffix = ".action.command";
      }
      {
        runtime = "kiro";
        path = ["ai" "kiro" "hooks" "probe"];
        value = {
          trigger = "UserPromptSubmit";
          action = {
            command = "true";
            prompt = "probe";
          };
        };
        suffix = ".action.prompt";
      }
    ]
    ++ lib.concatMap (runtime: [
      {
        inherit runtime;
        path = ["ai" "settings" "reasoningEffort"];
        value = "high";
      }
      {
        inherit runtime;
        path = ["ai" runtime "settings" "reasoningEffort"];
        value = "high";
      }
    ]) ["copilot" "kimchi" "kiro"];
  casePass = case: let
    mode = case.mode or "devenv";
    input = lib.setAttrByPath case.path case.value;
    needle = lib.concatStringsSep "." case.path + (case.suffix or "");
    enabled = {ai.${case.runtime}.enable = true;};
  in
    contains needle (evaluate mode (lib.recursiveUpdate enabled input))
    && !contains needle (evaluate mode enabled)
    && evaluate mode input == [];
  mcp = import ../../lib/mcp.nix {inherit lib;};
  darwinWarnings = v3: trustedMcpTools:
    import ../../lib/ai/delivery-warnings.nix {inherit lib;} {
      appRecord =
        (import ../../packages/kiro-cli/lib/mkKiro.nix {
          lib = harness.hmLib;
          inherit pkgs;
        })
        // {
          pkgs.stdenv.hostPlatform.isDarwin = true;
        };
      backend = "hm";
      inherit
        (harness.evalHm {
          ai.kiro = {
            enable = true;
            inherit v3 trustedMcpTools;
          };
        })
        config
        ;
    };
in {
  imports = [./runtime.nix];
  checks = {
    ai-warnings-darwin-trust = harness.mkTest "ai-warnings-darwin-trust" (
      contains "ai.kiro.trustedMcpTools" (darwinWarnings false ["@probe"])
      && darwinWarnings false [] == []
      && darwinWarnings true ["@probe"] == []
    );
    ai-warnings-delivery = harness.mkTest "ai-warnings-delivery" (
      lib.all (row: assert lib.assertMsg (rowCase row) "warning row ${policy.key row}"; true) gaps
      && lib.all (case: assert lib.assertMsg (casePass case) "warning case ${lib.concatStringsSep "." case.path}"; true) cases
    );
    ai-warnings-tombstones = harness.mkTest "ai-warnings-tombstones" (
      evaluate "hm" {
        ai.copilot = {
          enable = true;
          rules.probe = null;
        };
        ai.rules.probe.text = "probe";
      }
      == []
      && evaluate "hm" {
        ai.kimchi.enable = true;
        ai.rules.probe = null;
      }
      == []
      && evaluate "hm" {
        ai.copilot = {
          enable = true;
          context.text = "";
        };
      }
      == []
    );
    ai-warnings-mcp-assertions = harness.mkTest "ai-warnings-mcp-assertions" (
      let
        valid = mcp.evalSettings "gitlab-mcp" {
          assertions = [
            {
              assertion = true;
              message = "positive control";
            }
          ];
        };
        invalid = builtins.tryEval (mcp.evalSettings "gitlab-mcp" {
          assertions = [
            {
              assertion = false;
              message = "first settings failure";
            }
            {
              assertion = false;
              message = "second settings failure";
            }
          ];
        });
      in
        valid.instanceUrl == null && !(valid ? assertions) && !invalid.success
    );
  };
}
