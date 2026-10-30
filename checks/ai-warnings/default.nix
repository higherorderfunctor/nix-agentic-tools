{
  harness,
  lib,
  pkgs,
  ...
}: let
  policy = import ../../config/ai-delivery.nix {inherit lib;};
  reasonsFor = import ../../lib/ai/app/supportReasons.nix;
  settingsProbes = import ../../lib/testing/normalized-settings-probes.nix {inherit lib;};
  # lib/testing/module-harness.nix declares `warnings` in both backend stubs,
  # so this reads the module-system branch of mkBackendTransform rather than
  # extending the eval to create the option a real backend always has.
  evalConfig = mode: config:
    (
      if mode == "hm"
      then harness.evalHm config
      else harness.evalDevenv config
    )
    .config;
  evaluate = mode: config: (evalConfig mode config).warnings;
  optionPaths = import ../../lib/ai/option-paths.nix {
    lib = harness.hmLib;
    inherit pkgs;
  };
  inherit (optionPaths) records;
  declaredPaths = lib.genAttrs policy.modes (mode:
    map (option: option.loc) (lib.optionAttrSetToDocList
      (
        if mode == "hm"
        then harness.evalHm {}
        else harness.evalDevenv {}
      ).options));
  # Refuse an inputOptions path that is not a declared option, including the
  # retired ai.kiro.native.settings and ai.kiro.environmentVariables paths.
  inputsDeclared = lib.all (row:
    lib.all (path:
      lib.assertMsg (builtins.elem path declaredPaths.${row.mode})
      "delivery row ${policy.key row}: inputOptions path ${lib.showOption path} is not a declared option")
    (row.inputOptions or [])) (lib.concatMap policy.writersOf policy.rows);
  contains = needle: messages: lib.any (lib.hasInfix needle) messages;
  sample = {
    agents.probe = {
      description = "probe";
      instructions.text = "probe";
    };
    context.text = "probe";
    environmentVariables.PROBE = "value";
    hooks.PreToolUse = [{hooks = [{command = "true";}];}];
    jail.enable = true;
    mcpServers.probe.command = "probe";
    permissions = [
      {
        capability = "shell";
        effect = "allow";
      }
    ];
    rules.probe.text = "probe";
    shell = pkgs.bash;
    skills.probe = ../../packages/claude-code/checks/fixtures/claude-skills/skill-a;
  };
  inherit (settingsProbes) requestFields resolvedSettingSample settingSample settingsFields;
  # Every absent or inert primary row gets a populated request and an empty
  # control through the actual factory. Unsupported runtime options use root.
  gaps = lib.filter (row: row.primitive == "notApplicable" || row ? deliveryGap) policy.rows;
  rowCase = row: let
    enabled = harness.setEnable row.ecosystem true;
    empty = evaluate row.mode enabled;
    warns = field: path: let
      warningPath = path ++ lib.optional (row.surface == "settings") field;
      value =
        if row.surface == "settings"
        then settingSample field
        else sample.${row.surface};
      messages = evaluate row.mode (lib.recursiveUpdate enabled (lib.setAttrByPath warningPath value));
      needle = "${lib.showOption warningPath} is set but ${row.mode} does not deliver it to ${row.ecosystem} (reason: ${row.deliveryGap or row.reason})";
    in
      builtins.elem needle messages
      && !(builtins.elem needle empty);
    # Policy rows probe normalized settings at the portable root.
    path =
      if row.surface == "settings"
      then ["ai" "settings"]
      else if row.surface == "permissions"
      then ["ai" row.ecosystem "permissions"]
      else ["ai" row.surface];
  in
    # No permissions option or translation exists for these runtimes, so there
    # is nothing to probe. Assert the EMPTY input list rather than skipping the
    # row: a row that later grows an input option then stops passing by
    # default instead of staying silently unexercised.
    if row.surface == "permissions" && row.ecosystem != "kiro"
    then row.inputOptions == []
    else lib.all (field: warns field path) (requestFields row.surface);
  # Conditional record gaps keep focused requests that trigger their predicates.
  requestedCases =
    map (runtime: {
      inherit runtime;
      surface = "agents";
      gapPath = ["tools"];
      path = ["ai" "agents" "probe"];
      value = sample.agents.probe // {tools = ["Read"];};
    }) ["codex" "kimchi" "kiro"]
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
                package = pkgs.hello;
                settings.probe = true;
              }.${
                field
              };
          };
        suffix = ".${field}";
      }) (
        if http
        then ["args" "package" "settings"]
        else ["settings"]
      )) [false true]
    # A tool policy value with no surface on the runtime or backend.
    ++ map (runtime: {
      inherit runtime;
      surface = "mcpServers";
      gapPath = ["toolPolicy"];
      path = ["ai" "mcpServers" "probe"];
      value = {
        command = "probe";
        toolPolicy.probe = "disabled";
      };
    }) ["kimchi" "kiro"]
    ++ [
      {
        runtime = "claude";
        path = ["ai" "claude" "plugins"];
        value.probe = pkgs.emptyDirectory;
      }
      {
        runtime = "kiro";
        path = ["ai" "rules" "probe"];
        value = {
          text = "probe";
          inclusion = ["manual"];
        };
        surface = "rules";
        gapPath = ["inclusion"];
      }
      {
        runtime = "kiro";
        path = ["ai" "kiro" "rules" "probe"];
        value = {
          text = "probe";
          inclusion = "manual";
        };
        surface = "rules";
        gapPath = ["inclusion"];
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
        surface = "rules";
        gapPath = ["inclusion"];
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
    ];
  cases = lib.concatMap (case:
    if case ? gapPath && !(case ? mode)
    then map (mode: case // {inherit mode;}) policy.modes
    else [case])
  requestedCases;
  sharedSurfaces = (harness.evalDevenv {}).config.ai.internal.sharedSurfaces;
  # Refuse a newly registered surface or nested gap without a populated probe.
  gapSamples.hooks.PermissionRequest = sample.hooks.PreToolUse;
  sampleAt = surface: path:
    lib.attrByPath ([surface] ++ path)
    (throw "warning sample missing for ${lib.showOption (["ai" surface] ++ path)}")
    (
      if path == []
      then sample
      else lib.recursiveUpdate sample gapSamples
    );
  supportFor = runtime: surface: records.${runtime}.surfaceSupport.${surface} or {};
  surfacePaths = runtime: surface: let
    support = supportFor runtime surface;
  in
    [["ai" surface]]
    ++ lib.optional ((support.backends or []) != []) (optionPaths.pool runtime surface);
  surfaceCells = lib.concatMap (runtime:
    lib.concatMap (surface:
      map (mode: {
        inherit mode runtime surface;
        support = supportFor runtime surface;
      })
      policy.modes)
    sharedSurfaces)
  (builtins.attrNames records);
  delivered = cell: builtins.elem cell.mode (cell.support.backends or []);
  surfaceCases = lib.concatMap (cell:
    lib.concatMap (path:
      map (field:
        cell
        // {
          inherit field;
          path = path ++ lib.optional (field != null) field;
          value =
            if field == null
            then sampleAt cell.surface []
            else settingSample field;
        })
      (requestFields cell.surface))
    (surfacePaths cell.runtime cell.surface))
  surfaceCells;
  absenceReason = case:
    case.support.reason or (let
      writers = lib.concatMap policy.writersOf (lib.filter (row:
        row.ecosystem == case.runtime && row.surface == case.surface && row.mode == case.mode)
      policy.rows);
      absent = lib.filter (writer:
        (writer.primitive == "notApplicable" || writer ? deliveryGap)
        && builtins.elem ["ai" case.surface] (writer.inputOptions or []))
      writers;
    in
      if builtins.length absent == 1
      then (builtins.head absent).deliveryGap or (builtins.head absent).reason
      else throw "expected one policy absence writer for ${case.runtime}/${case.mode}/${case.surface}");
  deliveredCase = case:
    delivered case && (case.field == null || builtins.elem case.field (case.support.fields or []));
  unavailableCases = lib.filter (case: !(deliveredCase case)) surfaceCases;
  missingCases =
    map (case:
      case
      // {
        reason =
          if delivered case
          then (reasonsFor case.runtime).settingsField
          else absenceReason case;
        count = 1;
      })
    (let
      runtimeCases = lib.filter (case: builtins.elemAt case.path 1 == case.runtime) unavailableCases;
    in
      unavailableCases
      # Root and runtime pool both set still warn once, naming the runtime pool.
      ++ map (case: case // {extra = lib.setAttrByPath (["ai" case.surface] ++ lib.optional (case.field != null) case.field) case.value;}) runtimeCases
      # A value set only on the public normalized option warns too.
      ++ map (case:
        case
        // {
          path = lib.init (optionPaths.pool case.runtime case.surface) ++ ["normalized" case.surface] ++ lib.optional (case.field != null) case.field;
          value =
            if case.field != null
            then resolvedSettingSample case.field
            else case.value;
        })
      runtimeCases);
  conditional = gap: gap ? when || (gap.each or false);
  staticCases = lib.concatMap (cell:
    map (gap:
      cell
      // {
        count = 1;
        path = ["ai" cell.surface] ++ gap.path;
        inherit (gap) reason;
        value = sampleAt cell.surface gap.path;
      })
    (lib.filter (gap: !(conditional gap)) (cell.support.gaps or [])))
  (lib.filter delivered surfaceCells);
  gapCases = missingCases ++ staticCases;
  # Kimchi's only static gap, PermissionRequest, is not a native hook option.
  # A fixture exposes a dropped field in a pool with root copy-down instead.
  staticGapInputsPass = let
    record = harness.aiBase.app.mkRuntime {
      inherit pkgs;
      name = "testapp";
      surfaceSupport.settings = {
        fields = ["inference" "reasoningEffort"];
        gaps = [
          {
            path = ["inference" "url"];
            reason = "testapp drops the inference URL.";
          }
        ];
      };
    };
    surface = "settings";
    gap = builtins.head record.surfaceSupport.${surface}.gaps;
    rootPath = ["ai" surface "inference"];
    poolPath = ["ai" record.name surface "inference"];
    normalizedPath = ["ai" record.name "normalized" surface "inference"];
    rootInput = lib.setAttrByPath rootPath (settingSample "inference");
    poolInput = lib.setAttrByPath poolPath (settingSample "inference");
    inputs =
      map (path: {
        config = lib.setAttrByPath path (
          if path == normalizedPath
          then resolvedSettingSample "inference"
          else settingSample "inference"
        );
        warningPath =
          if path == normalizedPath
          then normalizedPath ++ ["url"]
          else poolPath ++ ["url"];
      }) [rootPath poolPath normalizedPath]
      ++ [
        {
          config = lib.recursiveUpdate rootInput poolInput;
          warningPath = poolPath ++ ["url"];
        }
        {
          config = lib.recursiveUpdate rootInput {
            ai.${record.name}.${surface} = {
              inference = {
                key = lib.mkForce null;
                url = lib.mkForce null;
              };
              reasoningEffort = "high";
            };
          };
          warningPath = rootPath ++ ["url"];
        }
      ];
  in
    lib.all (mode: let
      evaluate = enabled: config:
        (lib.evalModules {
          modules = [
            harness.aiBase.sharedOptions
            (
              if mode == "hm"
              then harness.hmStubs
              else harness.devenvStubs
            )
            (harness.aiBase.app.${mode + "Transform"} record)
            {config = lib.recursiveUpdate config {ai.${record.name}.enable = enabled;};}
          ];
        }).config.warnings;
    in
      evaluate true {}
      == []
      && evaluate true {ai.${record.name}.${surface}.reasoningEffort = "high";} == []
      && lib.all (input:
        evaluate true input.config
        == [
          (expectedMessage {
            inherit mode;
            inherit (gap) reason;
            path = input.warningPath;
            runtime = record.name;
          })
        ]
        && evaluate false input.config == [])
      inputs)
    policy.modes;
  conditionalGaps = lib.concatMap (cell:
    map (gap: cell // {inherit gap;})
    (lib.filter conditional (cell.support.gaps or [])))
  (lib.filter delivered surfaceCells);
  matchesGap = case: recorded:
    case.runtime
    == recorded.runtime
    && (case.surface or null) == recorded.surface
    && (case.gapPath or []) == recorded.gap.path
    && caseMode case == recorded.mode;
  conditionalDeclarations = lib.concatMap (runtime:
    lib.concatMap (surface:
      map (gap: {inherit gap runtime surface;})
      (lib.filter conditional (records.${runtime}.surfaceSupport.${surface}.gaps or [])))
    (builtins.attrNames records.${runtime}.surfaceSupport))
  (builtins.attrNames records);
  # Every declaration needs a reachable witness, even before activation filters.
  declarationsCovered = lib.all (declared:
    assert lib.assertMsg (lib.any (recorded:
      recorded.runtime
      == declared.runtime
      && recorded.surface == declared.surface
      && recorded.gap.path == declared.gap.path
      && lib.any (case: matchesGap case recorded) cases)
    conditionalGaps)
    "conditional warning declaration has no reachable case: ${declared.runtime}/${declared.surface}/${lib.showOption declared.gap.path}"; true)
  conditionalDeclarations;
  # Each active backend also needs its own explicit request.
  conditionalCovered = lib.all (recorded:
    assert lib.assertMsg (lib.any (case: matchesGap case recorded) cases)
    "conditional warning gap has no case: ${recorded.runtime}/${recorded.mode}/${recorded.surface}/${lib.showOption recorded.gap.path}"; true)
  conditionalGaps;
  supportedCases = lib.filter deliveredCase surfaceCases;
  consumedRootsQuiet = lib.all (case: let
    messages =
      evaluate case.mode (lib.recursiveUpdate (harness.setEnable case.runtime true)
        (lib.setAttrByPath case.path case.value));
    allowed = map expectedMessage (lib.filter (gap:
      gap.runtime == case.runtime && gap.mode == case.mode && gap.path == case.path)
    staticCases);
    prefix = "${lib.showOption case.path} is set but ${case.mode} does not deliver it to ${case.runtime} (reason:";
  in
    lib.assertMsg (lib.all (message:
      !(lib.hasPrefix prefix message)
      || builtins.elem message allowed)
    messages)
    "supported surface warned: ${case.runtime}/${case.mode}/${lib.showOption case.path}")
  supportedCases;
  expectedMessage = case: "${lib.showOption case.path} is set but ${case.mode} does not deliver it to ${case.runtime} (reason: ${case.reason})";
  portableEventSilent = lib.all (mode:
    evaluate mode (lib.recursiveUpdate (harness.setEnable "claude" true)
      (lib.setAttrByPath ["ai" "hooks" "PermissionRequest"] gapSamples.hooks.PermissionRequest))
    == [])
  policy.modes;
  # Pin support before evaluating writers that require their settings fields.
  settingsFieldsSilent = let
    # Pin existing delivery independently of the declaration being tested.
    expectedConsumers = {
      inference = ["claude" "codex"];
      reasoningEffort = ["claude" "codex" "kimchi"];
    };
  in
    lib.all (case: let
      enabled = harness.setEnable case.runtime true;
    in
      deliveredCase case
      && evaluate case.mode (lib.recursiveUpdate enabled (lib.setAttrByPath case.path case.value))
      == evaluate case.mode enabled)
    (lib.filter (case:
      case.field
      != null
      && (deliveredCase case || builtins.elem case.runtime (expectedConsumers.${case.field} or [])))
    surfaceCases);
  settingsPolicyChildren =
    # Real delivered records consume every field; this fixture must have a gap.
    policy.settingsGaps "testapp" {
      backends = ["hm"];
      fields = builtins.tail settingsFields;
    }
    == [
      {
        inputOptions = [["ai" "settings" (builtins.head settingsFields)]];
        primitive = "notApplicable";
        reason = "testapp's surfaceSupport.settings.fields does not consume this normalized setting.";
      }
    ]
    && lib.all (row: let
      support = supportFor row.ecosystem "settings";
      expected = lib.subtractLists (support.fields or []) settingsFields;
      children = lib.filter (writer:
        lib.any (path: builtins.length path == 3 && lib.take 2 path == ["ai" "settings"])
        (writer.inputOptions or [])) (row.additionalWriters or []);
      reason = (reasonsFor row.ecosystem).settingsField;
    in
      map (writer: builtins.elemAt (builtins.head writer.inputOptions) 2) children
      == expected
      && lib.all (writer: writer.primitive == "notApplicable" && writer.reason == reason) children)
    (lib.filter (row:
      row.surface
      == "settings"
      && builtins.elem row.mode ((supportFor row.ecosystem "settings").backends or []))
    policy.rows);
  caseMode = case: case.mode or "devenv";
  # Memoize identical enabled-empty controls across both case collections.
  emptyCaseWarnings = lib.mapAttrs (mode: modeCases:
    lib.genAttrs (map (case: case.runtime) modeCases)
    (runtime: evaluate mode (harness.setEnable runtime true)))
  (lib.groupBy caseMode (cases ++ gapCases));
  casePass = case: let
    mode = caseMode case;
    input = lib.recursiveUpdate (case.extra or {}) (lib.setAttrByPath case.path case.value);
    recorded = lib.filter (matchesGap case) conditionalGaps;
    gap =
      if case ? gapPath
      then
        if builtins.length recorded == 1
        then (builtins.head recorded).gap
        else throw "conditional warning case must match one record gap: ${case.runtime}/${mode}/${lib.showOption case.path}"
      else null;
    warningPath =
      if gap != null && (gap.each or false)
      then case.path ++ case.gapPath
      else case.path;
    recordedReason =
      if gap == null
      then case.reason or null
      else gap.reason;
    reason =
      if builtins.isFunction recordedReason
      then
        recordedReason {
          backend = mode;
          cfg = evaluation.ai.${case.runtime};
          name = lib.last case.path;
          inherit (case) path value;
        }
      else recordedReason;
    needle =
      if reason != null
      then
        expectedMessage (case
          // {
            inherit mode reason;
            path = warningPath;
          })
      else lib.showOption case.path + (case.suffix or "");
    present =
      if reason != null
      then builtins.elem needle
      else contains needle;
    enabled = harness.setEnable case.runtime true;
    evaluation = evalConfig mode (lib.recursiveUpdate enabled input);
    messages = evaluation.warnings;
  in
    present messages
    && (!(case ? count) || builtins.length messages == case.count)
    && !present emptyCaseWarnings.${mode}.${case.runtime}
    && evaluate mode input == [];
  kiroManualPrioritySilent = lib.all (config: evaluate "devenv" config == []) [
    {
      ai = {
        kiro.cli.enable = true;
        rules.probe = {
          inclusion = ["always" "manual"];
          text = "root";
        };
      };
    }
    {
      ai = {
        kiro = {
          cli.enable = true;
          rules.probe = {
            inclusion = "always";
            text = "native";
          };
        };
        rules.probe = {
          inclusion = ["manual"];
          text = "root";
        };
      };
    }
  ];
  # config/ai-delivery-facts.nix is pure `{lib}` data, so it lists the
  # runtimes with a native agent layer by name. The record is the source of
  # truth: `native.agents` must be an agents row's input exactly when the
  # runtime's record has `agentNativeType`.
  nativeAgentsListed = lib.all (row:
    builtins.elem ["ai" row.ecosystem "native" "agents"] (row.inputOptions or [])
    == (records.${row.ecosystem} ? agentNativeType))
  (lib.filter (row: row.surface == "agents") policy.rows);
  deliveryWarnings = import ../../lib/ai/delivery-warnings.nix {inherit lib;};
  mcp = import ../../lib/mcp.nix {inherit lib;};
  # These four input combinations exercise the warning interface directly;
  # args, package, and settings retain their module-backed cases above.
  mcpFieldCases = [
    {
      field = "command";
      fixture = {
        command = "probe";
        url = "https://example.invalid";
      };
    }
    {
      field = "env";
      fixture = {
        env.PROBE = "";
        url = "https://example.invalid";
      };
    }
    {
      field = "headers";
      fixture = {
        command = "probe";
        headers.Authorization = "";
      };
    }
    {
      field = "timeout";
      fixture = {
        command = "probe";
        timeout = 1;
      };
    }
  ];
  # The hand-built config carries the module-derived shared-surface list, so
  # the decomposition reads real surfaces (all absent here) instead of none.
  mcpFieldWarnings = enable: fixture:
    deliveryWarnings {
      appRecord = records.claude;
      backend = "devenv";
      config.ai = {
        claude = {
          inherit enable;
          mcpServers.probe = fixture;
        };
        internal = {inherit sharedSurfaces;};
      };
    };
  mcpFieldCasesPass =
    lib.all (case: let
      messages = mcpFieldWarnings true case.fixture;
    in
      builtins.length messages
      == 1
      && lib.hasPrefix "ai.claude.mcpServers.probe.${case.field} is set but devenv does not deliver it to claude (reason:" (builtins.head messages)
      && mcpFieldWarnings false case.fixture == [])
    mcpFieldCases
    && lib.all (fixture: mcpFieldWarnings true fixture == []) [
      {url = "https://example.invalid";}
      {command = "probe";}
    ];
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
        cli.enable = true;
        cli = {inherit trustedMcpTools v3;};
      };
    };
    platformPkgs =
      pkgs
      // {
        stdenv =
          pkgs.stdenv
          // {
            hostPlatform = pkgs.stdenv.hostPlatform // {isDarwin = darwin;};
          };
      };
    record = import ../../packages/kiro-cli/lib/mkKiro.nix {
      lib = harness.hmLib;
      pkgs = platformPkgs;
    };
  in
    (lib.evalModules {
      modules = [
        harness.aiBase.sharedOptions
        (
          if backend == "hm"
          then harness.hmStubs
          else harness.devenvStubs
        )
        (harness.aiBase.app.${backend + "Transform"} record)
        {config = declaration;}
      ];
    }).config.warnings;
in {
  imports = [./runtime.nix];
  checks = {
    ai-warnings-darwin-trust = harness.mkTest "ai-warnings-darwin-trust" (
      # Withheld: Darwin under either engine, and the v3 `acp` arm anywhere.
      contains "ai.kiro.cli.trustedMcpTools" (trustWarnings {
        backend = "hm";
        darwin = true;
      })
      && contains "ai.kiro.cli.trustedMcpTools" (trustWarnings {
        backend = "devenv";
        darwin = true;
        v3 = true;
      })
      && contains "ai.kiro.cli.trustedMcpTools" (trustWarnings {
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
      lib.assertMsg settingsFieldsSilent "existing and declared normalized settings consumers must stay supported and quiet"
      && lib.all (row: assert lib.assertMsg (rowCase row) "warning row ${policy.key row}"; true) gaps
      && lib.all (case: assert lib.assertMsg (casePass case) "warning case ${lib.concatStringsSep "." case.path}"; true) cases
      && lib.all (case: assert lib.assertMsg (casePass case) "warning gap ${case.runtime}/${case.mode}/${lib.showOption case.path}"; true) gapCases
      && lib.assertMsg staticGapInputsPass "static gaps warn once for root, runtime pool, combined and normalized inputs, with empty and disabled controls"
      && declarationsCovered
      && conditionalCovered
      && lib.assertMsg portableEventSilent "Claude delivers the portable PermissionRequest event"
      && lib.assertMsg consumedRootsQuiet "consumed shared surfaces must not warn"
      && lib.assertMsg mcpFieldCasesPass "Claude MCP field warnings match their paths, backend, runtime, count, and disabled/absent controls"
      && lib.assertMsg kiroManualPrioritySilent "Kiro manual warnings follow the selected trigger and native replacement"
      && lib.assertMsg settingsPolicyChildren "policy must list every undeclared normalized settings field"
      && lib.assertMsg nativeAgentsListed "config/ai-delivery-facts.nix must list `ai.<runtime>.native.agents` as an agents input exactly for the runtimes whose record has `agentNativeType`"
    );
    ai-warnings-delivery-input-options = harness.mkTest "ai-warnings-delivery-input-options" inputsDeclared;
    ai-warnings-kiro-hook-prompts = harness.mkTest "ai-warnings-kiro-hook-prompts" (
      lib.all (mode: let
        warningsFor = extra:
          evaluate mode {
            ai.kiro = {
              cli.enable = true;
              hooks.probe =
                lib.recursiveUpdate {
                  trigger = "UserPromptSubmit";
                  action.command = "true";
                }
                extra;
            };
          };
        unset = warningsFor {};
        withPrompt = warningsFor {action.prompt.text = "probe";};
      in
        assert lib.assertMsg (unset == []) "${mode}: command hook with no prompt warned: ${builtins.toJSON unset}";
          contains "ai.kiro.hooks.probe.action.prompt" withPrompt)
      ["devenv" "hm"]
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
    # A context or rule unit whose file is switched off (`enable =
    # false`) or replaced with the consumer's own bytes warns, naming the
    # unit, the file option that dropped it and a per-runtime way to withhold
    # it; the warning is what makes the drop visible. Withholding the unit or
    # having nothing to carry is quiet.
    ai-warnings-switched-off-files = harness.mkTest "ai-warnings-switched-off-files" (
      let
        offMessage = messages: unit: file: remedy:
          lib.any (message:
            lib.hasInfix "${unit} is set but" message
            # A layer-1 (`files`) entry has `enable` of its own.
            && lib.hasInfix "${file}${lib.optionalString (!lib.hasInfix ".files." file) ".content"}.enable = false switches off" message
            && lib.hasInfix remedy message)
          messages;
        # Shared context and rules warn when another runtime overrides the
        # final AGENTS.md entry.
        sharedRuntimes = ["codex" "kimchi" "kiro"];
        sharedWarnings = extra:
          evaluate "devenv" (lib.foldl' lib.recursiveUpdate {
              ai = {
                context.text = "CTX";
                copilot.enable = true;
                rules.probe.text = "RULE";
              };
            }
            (map (runtime: harness.setEnable runtime true) sharedRuntimes ++ [extra]));
        sharedCodexOff = sharedWarnings {ai.codex.files."AGENTS.md".enable = false;};
        sharedOff = sharedWarnings {ai.kiro.files."AGENTS.md".enable = false;};
        sharedReplaced = sharedWarnings {ai.kiro.files."AGENTS.md".content.text = "MINE";};
        # Copilot carries shared and runtime context in its own file. Dropping
        # that file warns for both inputs, while its named rules remain intact.
        copilotWarnings = entry:
          evaluate "devenv" {
            ai = {
              context.text = "CTX";
              copilot = {
                enable = true;
                files.".github/copilot-instructions.md" = entry;
                github.context.text = "COPILOT-CTX";
              };
              rules.probe.text = "RULE";
            };
          };
        copilotOff = copilotWarnings {enable = false;};
        copilotReplaced = copilotWarnings {content.text = "MINE";};
        copilotContextFile = ''ai.copilot.files.".github/copilot-instructions.md"'';
        copilotContextRemedy = "ai.copilot.github.normalized.context = lib.mkForce null";
        # Codex's user AGENTS.md on Home Manager.
        hmCodexOff = evaluate "hm" {
          ai = {
            codex = {
              enable = true;
              files.".codex/AGENTS.md".enable = false;
              rules.local.text = "LOCAL";
            };
            rules.probe.text = "RULE";
          };
        };
        # One scoped Kiro steering file on devenv; Claude rule file on HM.
        steeringOff = evaluate "devenv" {
          ai.kiro = {
            cli.enable = true;
            files.".kiro/steering/scoped.md".enable = false;
            rules.scoped = {
              matcher = ["src/**"];
              text = "SCOPED";
            };
          };
        };
        claudeOff = evaluate "hm" {
          ai = {
            claude = {
              enable = true;
              files.".claude/rules/probe.md".enable = false;
            };
            rules.probe.text = "RULE";
          };
        };
        # Quiet controls.
        withheld = evaluate "devenv" {
          ai = {
            codex = {
              enable = true;
              files."AGENTS.md".enable = false;
              normalized.context = lib.mkForce null;
              rules.probe.enable = false;
            };
            context.text = "CTX";
            rules.probe.text = "RULE";
          };
        };
        # A whole-file replacement drops the units the generated file carried,
        # on the shared devenv AGENTS.md and on each backend's own files.
        replacedMessage = messages: unit: file: remedy:
          lib.any (message:
            lib.hasInfix "${unit} is set but" message
            && lib.hasInfix "${file}.content replaces" message
            && lib.hasInfix remedy message)
          messages;
        replaced = evaluate "devenv" {
          ai = {
            codex = {
              enable = true;
              files."AGENTS.md".content.text = "MINE";
            };
            context.text = "CTX";
            rules.probe.text = "RULE";
          };
        };
        hmCodexReplaced = evaluate "hm" {
          ai = {
            codex = {
              enable = true;
              files.".codex/AGENTS.md".content.text = "MINE";
            };
            rules.probe.text = "RULE";
          };
        };
        claudeReplaced = evaluate "devenv" {
          ai = {
            claude = {
              enable = true;
              files.".claude/rules/probe.md".content.source = pkgs.writeText "mine" "MINE";
            };
            rules.probe.text = "RULE";
          };
        };
        # Changing how a generated file lands keeps its bytes: quiet.
        symlinked = evaluate "hm" {
          ai = {
            claude = {
              enable = true;
              files.".claude/rules/probe.md".method = "symlink";
            };
            rules.probe.text = "RULE";
          };
        };
        # Ordinary generated entries never warn about replacement when no
        # final content override was declared.
        ordinary = mode:
          evaluate mode {
            ai = {
              claude.enable = true;
              codex.enable = true;
              context.text = "CTX";
              copilot.enable = true;
              kimchi.enable = true;
              kiro.cli.enable = true;
              rules = {
                probe.text = "RULE";
                scoped = {
                  matcher = ["src/**"];
                  text = "SCOPED";
                };
              };
            };
          };
        nothing = evaluate "devenv" {
          ai.codex = {
            enable = true;
            files."AGENTS.md".enable = false;
          };
        };
        nothingReplaced = evaluate "devenv" {
          ai.codex = {
            enable = true;
            files."AGENTS.md".content.text = "MINE";
          };
        };
      in
        lib.all (runtime: let
          contextRemedy = "${lib.showOption (lib.init (optionPaths.pool runtime "context") ++ ["normalized" "context"])} = lib.mkForce null";
          rulesRemedy = "${lib.showOption (optionPaths.pool runtime "rules" ++ ["probe" "enable"])} = false";
        in
          offMessage sharedOff "ai.context" ''ai.kiro.files."AGENTS.md"'' contextRemedy
          && offMessage sharedCodexOff "ai.context" ''ai.codex.files."AGENTS.md"'' contextRemedy
          && replacedMessage sharedReplaced "ai.context" ''ai.kiro.files."AGENTS.md"'' contextRemedy
          && offMessage sharedOff "ai.rules.probe" ''ai.kiro.files."AGENTS.md"'' rulesRemedy
          && offMessage sharedCodexOff "ai.rules.probe" ''ai.codex.files."AGENTS.md"'' rulesRemedy
          && replacedMessage sharedReplaced "ai.rules.probe" ''ai.kiro.files."AGENTS.md"'' rulesRemedy)
        sharedRuntimes
        && lib.all (unit:
          offMessage copilotOff unit copilotContextFile copilotContextRemedy
          && replacedMessage copilotReplaced unit copilotContextFile copilotContextRemedy)
        ["ai.context" "ai.copilot.github.context"]
        && !(contains "does not deliver it to copilot" (sharedOff ++ sharedCodexOff ++ sharedReplaced))
        && !(contains "ai.rules.probe is set but devenv does not deliver it to copilot" (copilotOff ++ copilotReplaced))
        && offMessage hmCodexOff "ai.rules.probe" ''ai.codex.files.".codex/AGENTS.md"'' "ai.codex.rules.probe.enable = false"
        && offMessage hmCodexOff "ai.codex.rules.local" ''ai.codex.files.".codex/AGENTS.md"'' "ai.codex.rules.local.enable = false"
        && offMessage steeringOff "ai.kiro.rules.scoped" ''ai.kiro.files.".kiro/steering/scoped.md"'' "ai.kiro.rules.scoped.enable = false"
        && offMessage claudeOff "ai.rules.probe" ''ai.claude.files.".claude/rules/probe.md"'' "ai.claude.rules.probe.enable = false"
        && replacedMessage replaced "ai.rules.probe" ''ai.codex.files."AGENTS.md"'' "ai.codex.rules.probe.enable = false"
        && replacedMessage replaced "ai.context" ''ai.codex.files."AGENTS.md"'' "ai.codex.normalized.context = lib.mkForce null"
        && replacedMessage hmCodexReplaced "ai.rules.probe" ''ai.codex.files.".codex/AGENTS.md"'' "ai.codex.rules.probe.enable = false"
        && replacedMessage claudeReplaced "ai.rules.probe" ''ai.claude.files.".claude/rules/probe.md"'' "ai.claude.rules.probe.enable = false"
        && !(contains "switches off" replaced)
        && !(contains "the file that carries it" withheld)
        && !(contains "the file that carries it" symlinked)
        && !(contains "the file that carries it" nothing)
        && !(contains "the file that carries it" (ordinary "hm"))
        && !(contains "the file that carries it" (ordinary "devenv"))
        && !(contains "the file that carries it" nothingReplaced)
    );

    ai-warnings-tombstones = harness.mkTest "ai-warnings-tombstones" (
      evaluate "hm" {
        ai.copilot = {
          enable = true;
          github.rules.probe.enable = false;
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
          github.context.text = "";
        };
      }
      == []
    );
  };
}
