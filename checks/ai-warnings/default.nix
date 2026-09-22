{
  harness,
  lib,
  pkgs,
  ...
}: let
  policy = import ../../config/ai-delivery.nix {inherit lib;};
  # lib/testing/module-harness.nix declares `warnings` in both backend stubs,
  # so this reads the module-system branch of mkBackendTransform rather than
  # extending the eval to create the option a real backend always has.
  evaluate = mode: config:
    (
      if mode == "hm"
      then harness.evalHm config
      else harness.evalDevenv config
    )
    .config
    .warnings;
  records = lib.mapAttrs (_: file:
    import file {
      lib = harness.hmLib;
      inherit pkgs;
    }) {
    claude = ../../packages/claude-code/lib/mkClaude.nix;
    codex = ../../packages/chatgpt-codex/lib/mkCodex.nix;
    copilot = ../../packages/copilot-cli/lib/mkCopilot.nix;
    kimchi = ../../packages/kimchi/lib/mkKimchi.nix;
    kiro = ../../packages/kiro-cli/lib/mkKiro.nix;
  };
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
      then ["ai" row.ecosystem "native" "settings"]
      else if row.surface == "permissions"
      then ["ai" row.ecosystem "permissions"]
      else ["ai" row.surface];
    enabled = {ai.${row.ecosystem}.enable = true;};
    messages = evaluate row.mode (lib.recursiveUpdate enabled (lib.setAttrByPath path sample.${row.surface}));
    empty = evaluate row.mode enabled;
    needle = lib.showOption path;
  in
    # No permissions option or translation exists for these runtimes, so there
    # is nothing to probe. Assert the EMPTY input list rather than skipping the
    # row: a row that later grows an input option then stops passing by
    # default instead of staying silently unexercised.
    if row.surface == "permissions" && row.ecosystem != "kiro"
    then row.inputOptions == []
    # A bare root pool the runtime's capability gate excludes is deliberately
    # silent — there is no per-runtime option to tombstone it with, so the
    # warning would have no consumer remedy. The silence is the assertion.
    else if builtins.length path == 2 && !(builtins.elem row.surface records.${row.ecosystem}.supportedPools)
    then messages == [] && empty == []
    else
      contains needle messages
      && contains (row.deliveryGap or row.reason) messages
      && !contains needle empty;
  # `ai.kiro.trustedMcpTools` is NOT a case here: the wrapper appends
  # `--trust-tools` on both backends, so a devenv consumer setting it has no
  # delivery gap to be told about. The narrower withhold it does have — the v3
  # `acp` arm and Darwin's bundle-discovery launcher — is asserted by
  # ai-warnings-darwin-trust below.
  #
  # Root pools an incapable runtime excludes (`ai.agents`/`ai.hooks` on Kiro,
  # `ai.shell` on Kimchi and Copilot) are not cases either: they are silent by
  # design, and rowCase above asserts that silence.
  cases =
    [
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
        path = ["ai" "claude" "native" "settings" "mcpServers"];
        value.probe.command = "probe";
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
      # A consumer key may contain a dot of its own: `foo.bar.md` lands at key
      # `foo.bar`. The rendered path has to quote it, or the message names an
      # option that does not exist and cannot be pasted back.
      {
        runtime = "kiro";
        path = ["ai" "kiro" "rules" "foo.bar"];
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
            prompt = {text = "probe";};
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
            prompt = {text = "probe";};
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
            prompt = {text = "probe";};
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
    needle = lib.showOption case.path + (case.suffix or "");
    enabled = {ai.${case.runtime}.enable = true;};
  in
    contains needle (evaluate mode (lib.recursiveUpdate enabled input))
    && !contains needle (evaluate mode enabled)
    && evaluate mode input == [];
  mcp = import ../../lib/mcp.nix {inherit lib;};
  # `isDarwin` is forced in BOTH directions rather than left to the host: this
  # check runs on x86_64-linux and aarch64-darwin, so reading the real platform
  # would make the non-Darwin arms assert nothing on the Darwin runner.
  trustWarnings = {
    backend,
    darwin ? false,
    trustedMcpTools ? ["@probe"],
    v3 ? false,
  }: let
    declaration = {
      ai.kiro = {
        enable = true;
        inherit trustedMcpTools v3;
      };
    };
  in
    import ../../lib/ai/delivery-warnings.nix {inherit lib;} {
      appRecord = records.kiro // {pkgs.stdenv.hostPlatform.isDarwin = darwin;};
      inherit backend;
      inherit
        (
          if backend == "hm"
          then harness.evalHm declaration
          else harness.evalDevenv declaration
        )
        config
        ;
    };
  # A hand-built config, not a harness eval: every policy path goes through
  # lib.attrByPath, which answers `null` for a shared pool a minimal
  # composition never declared, and the real module trees always declare them
  # all. Each branch of `present` has to read that null as "nothing requested"
  # instead of crashing the whole evaluation.
  undeclaredSharedPools = backend:
    import ../../lib/ai/delivery-warnings.nix {inherit lib;} {
      appRecord = records.copilot;
      inherit backend;
      config.ai.copilot.enable = true;
    };
in {
  imports = [./runtime.nix];
  checks = {
    ai-warnings-darwin-trust = harness.mkTest "ai-warnings-darwin-trust" (
      # Withheld: Darwin under either engine, and the v3 `acp` arm anywhere.
      contains "ai.kiro.trustedMcpTools" (trustWarnings {
        backend = "hm";
        darwin = true;
      })
      && contains "ai.kiro.trustedMcpTools" (trustWarnings {
        backend = "devenv";
        darwin = true;
        v3 = true;
      })
      && contains "ai.kiro.trustedMcpTools" (trustWarnings {
        backend = "devenv";
        v3 = true;
      })
      # Recovered, or never withheld.
      && trustWarnings {
        backend = "hm";
        darwin = true;
        v3 = true;
      }
      == []
      && trustWarnings {
        backend = "hm";
        darwin = true;
        trustedMcpTools = [];
      }
      == []
      && trustWarnings {backend = "devenv";} == []
      && trustWarnings {backend = "hm";} == []
    );
    ai-warnings-delivery = harness.mkTest "ai-warnings-delivery" (
      lib.all (row: assert lib.assertMsg (rowCase row) "warning row ${policy.key row}"; true) gaps
      && lib.all (case: assert lib.assertMsg (casePass case) "warning case ${lib.concatStringsSep "." case.path}"; true) cases
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
    ai-warnings-tombstones = harness.mkTest "ai-warnings-tombstones" (
      evaluate "hm" {
        ai.copilot = {
          enable = true;
          rules.probe.enable = false;
        };
        ai.rules.probe.text = "probe";
      }
      == []
      && evaluate "hm" {
        ai.kimchi.enable = true;
        ai.rules.probe.enable = false;
      }
      == []
      && evaluate "hm" {
        ai.copilot = {
          enable = true;
          context.text = "";
        };
      }
      == []
      && undeclaredSharedPools "hm" == []
      && undeclaredSharedPools "devenv" == []
    );
  };
}
