{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) checkRows rejectsChange;
  rowsFrom = name: test: cases: let
    rows = lib.listToAttrs (map (case: lib.nameValuePair (name case) (test case)) cases);
  in
    assert lib.assertMsg (builtins.length (builtins.attrNames rows) == builtins.length cases)
    "warning case names must distinguish all inputs"; rows;
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
    proxy.http = "http://proxy.invalid:8080";
    rules.probe.text = "probe";
    shell = pkgs.bash;
    skills.probe = ../../packages/claude-code/checks/fixtures/claude-skills/skill-a;
  };
  inherit (settingsProbes) requestFields resolvedSettingSample settingSample;
  # Permissions are policy-only, with no portable root input. An absence
  # gaining an input must get a real probe rather than silently passing.
  policyOnlyCases = lib.filter (row:
    row.surface == "permissions" && (row.primitive == "notApplicable" || row ? deliveryGap))
  policy.rows;
  policyOnlyRows =
    rowsFrom
    (row: "absent ${policy.key row} cannot advertise an input with no declared permissions option")
    (row: row.inputOptions == [])
    policyOnlyCases;
  agentToolReasons = {
    codex = "Codex agents have no equivalent tool allowlist field.";
    kimchi = "Kimchi matches its own lowercase builtins, so the agent gets every tool. Set ai.kimchi.agents.probe to native Kimchi Markdown with its own `tools:` line to apply the guardrail there.";
    kiro = "Kiro takes capability tags, not Claude/Copilot tool names. Set ai.kiro.native.agents.probe.tools (capability tags) and permissions to apply the guardrail there.";
  };
  # Conditional record gaps keep focused requests that trigger their predicates.
  requestedCases =
    # Every agent adapter must identify the tools constraint it cannot honor.
    # With no adapter enabled, the root request is identical across runtimes.
    map (runtime: {
      inherit runtime;
      checkDisabled = runtime == "codex";
      surface = "agents";
      gapPath = ["tools"];
      path = ["ai" "agents" "probe"];
      value = sample.agents.probe // {tools = ["Read"];};
      reason = agentToolReasons.${runtime};
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
        suffix = [field];
        scenario =
          if http
          then "HTTP cannot carry ${field}"
          else "a raw stdio command bypasses ${field}";
        reason =
          if http
          then mcpReasons.http
          else "An explicit MCP command bypasses typed package settings.";
      }) (
        if http
        then ["args" "package" "settings"]
        else ["settings"]
      )) [false true]
    # Keep timeout gap witnesses here; checks/mcp-timeout/module-eval.nix
    # checks the enabled warning and accepted bound on both backends.
    ++ map (case: {
      inherit (case) runtime;
      coverageOnly = true;
      gapPath = ["timeout"];
      path = ["ai" "mcpServers" "probe"];
      surface = "mcpServers";
      value = {
        command = "probe";
        inherit (case) timeout;
      };
    }) [
      {
        runtime = "claude";
        timeout = 999;
      }
      {
        runtime = "kimchi";
        timeout = 2147483648;
      }
      {
        runtime = "kiro";
        timeout = 600001;
      }
    ]
    # A tool policy value with no surface on the runtime or backend.
    ++ [
      {
        gapPath = ["toolPolicy"];
        path = ["ai" "mcpServers" "probe"];
        runtime = "kimchi";
        surface = "mcpServers";
        value = {
          command = "probe";
          toolPolicy.probe = "disabled";
        };
      }
    ]
    # Keep the HM gap witness; checks/mcp-tool-policy/module-eval.nix checks
    # that HM delivers it through permissions.yaml without a warning.
    ++ map (mode: {
      inherit mode;
      coverageOnly = mode == "hm";
      gapPath = ["toolPolicy"];
      path = ["ai" "mcpServers" "probe"];
      reason = "Kiro reads tool policy only from permission rules under ~/.kiro (settings/permissions.yaml or workspace-roots/<hash>/), outside the devenv root, which neither writes there nor defines a new root, so only Home Manager delivers it and these tools keep Kiro's default: probe.";
      runtime = "kiro";
      surface = "mcpServers";
      value = {
        command = "probe";
        toolPolicy.probe = "disabled";
      };
    })
    policy.modes
    ++ [
      {
        runtime = "claude";
        path = ["ai" "claude" "plugins"];
        reason = "The devenv backend has no writer for this Claude surface.";
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
      # A consumer key may contain a dot of its own: `foo.bar.md` lands at key
      # `foo.bar`. The rendered path has to quote it, or the message names an
      # option that does not exist and cannot be pasted back.
      {
        runtime = "kiro";
        path = ["ai" "kiro" "rules" "foo.bar"];
        renderedPath = ''ai.kiro.rules."foo.bar".inclusion'';
        value = {
          text = "probe";
          inclusion = "manual";
        };
        surface = "rules";
        gapPath = ["inclusion"];
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
  absenceReason = case: let
    primary =
      policy.definitions.${case.surface}.${case.runtime}.${case.mode}
      // {
        inherit (case) mode surface;
        ecosystem = case.runtime;
      };
    recordReason = case.support.reason or (reasonsFor case.runtime).surface;
    absences = lib.filter (writer:
      (writer.primitive == "notApplicable" || writer ? deliveryGap)
      # Plain option trees list declared leaves under the root request;
      # inputsDeclared still checks each complete leaf path exactly.
      && lib.any (lib.lists.hasPrefix ["ai" case.surface]) (writer.inputOptions or []))
    (policy.writersOf primary);
  in
    # Each omitted root input must have exactly one absence writer.
    assert lib.assertMsg (builtins.length absences == 1)
    "expected one shared surface absence writer: ${case.runtime}/${case.mode}/${case.surface}"; recordReason;
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
        onlyWarning = true;
      })
    (let
      runtimeCases = lib.filter (case: builtins.elemAt case.path 1 == case.runtime) unavailableCases;
      # Kimchi's module check pins the root-only and both-set HM hook warnings.
      rootOnlyHook = case: case.runtime == "kimchi" && case.mode == "hm" && case.path == ["ai" "hooks"];
      # Owner module checks cover both-set Kimchi hooks and Copilot context
      # and skills; the factory settings-fields check covers per-field precedence.
      coveredPrecedence = case:
        (case.runtime == "copilot" && case.mode == "hm" && builtins.elem case.surface ["context" "skills"])
        || (case.runtime == "kimchi" && case.mode == "hm" && case.surface == "hooks")
        || (case.runtime == "kimchi" && case.surface == "settings" && case.field == "inference");
      standalone =
        lib.partition (case: lib.take 2 case.path == ["ai" case.surface])
        (lib.filter (case: !rootOnlyHook case) unavailableCases);
      # The root sample depends only on the path. With no runtime enabled,
      # one check per backend and root path catches a warning from any runtime.
      rootByInput = lib.groupBy (case: builtins.toJSON [case.mode case.path]) standalone.right;
    in
      standalone.wrong
      ++ lib.concatMap (lib.imap0 (index: case: case // {checkDisabled = index == 0;})) (builtins.attrValues rootByInput)
      # Root and runtime pool both set still warn once, naming the runtime pool.
      # The standalone pool case already checks for the same warning when empty.
      ++ map (case:
        case
        // {
          checkEmpty = false;
          extra = lib.setAttrByPath (["ai" case.surface] ++ lib.optional (case.field != null) case.field) case.value;
          scenario = "root and runtime pool both set: only the runtime pool should warn";
        })
      (lib.filter (case: !coveredPrecedence case) runtimeCases)
      # A value set only on the public normalized option warns too. Its
      # warning names a different path, so the empty pool check cannot catch it.
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
        onlyWarning = true;
        path = ["ai" cell.surface] ++ gap.path;
        inherit (gap) reason;
        value = sampleAt cell.surface gap.path;
      })
    (lib.filter (gap:
      !(conditional gap)
      # Kimchi's module check pins the warning for PermissionRequest alone.
      && !(cell.runtime == "kimchi" && cell.mode == "devenv" && cell.surface == "hooks" && gap.path == ["PermissionRequest"]))
    (cell.support.gaps or [])))
  (lib.filter delivered surfaceCells);
  gapCases = missingCases ++ staticCases;
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
  # Every declaration needs a reachable backend; conditionalCovered checks
  # the explicit witness for every such backend.
  declarationsCovered = lib.all (declared:
    assert lib.assertMsg (lib.any (recorded:
      recorded.runtime
      == declared.runtime
      && recorded.surface == declared.surface
      && recorded.gap.path == declared.gap.path)
    conditionalGaps)
    "conditional warning declaration has no reachable backend: ${declared.runtime}/${declared.surface}/${lib.showOption declared.gap.path}"; true)
  conditionalDeclarations;
  # Each active backend also needs its own explicit request.
  conditionalCovered = lib.all (recorded:
    assert lib.assertMsg (lib.any (case: matchesGap case recorded) cases)
    "conditional warning gap has no case: ${recorded.runtime}/${recorded.mode}/${recorded.surface}/${lib.showOption recorded.gap.path}"; true)
  conditionalGaps;
  # A supported input must remain quiet. Pin consumers so that removing a
  # settings declaration cannot turn a required quiet row into a warning row.
  expectedConsumers = {
    inference = ["claude" "codex"];
    reasoningEffort = ["claude" "codex" "kimchi"];
  };
  quietCases = lib.filter (case:
    deliveredCase case || (case.field != null && builtins.elem case.runtime (expectedConsumers.${case.field} or [])))
  surfaceCases;
  quietCase = case: let
    enabled = harness.setEnable case.runtime true;
    messages = evaluate case.mode (lib.recursiveUpdate enabled (lib.setAttrByPath case.path case.value));
    # A nested gap starts with a longer option path, not this warning prefix.
    prefix = "${lib.showOption case.path} is set but ${case.mode} does not deliver it to ${case.runtime} (reason:";
  in
    if case.field != null
    then deliveredCase case && messages == evaluate case.mode enabled
    else !(lib.any (lib.hasPrefix prefix) messages);
  expectedMessage = case: "${case.renderedPath or (lib.showOption case.path)} is set but ${case.mode} does not deliver it to ${case.runtime} (reason: ${case.reason})";
  portableEventSilent = lib.all (mode:
    evaluate mode (lib.recursiveUpdate (harness.setEnable "claude" true)
      (lib.setAttrByPath ["ai" "hooks" "PermissionRequest"] gapSamples.hooks.PermissionRequest))
    == [])
  policy.modes;
  # Kimchi accepts effort but not inference. The inventory must show the
  # omitted normalized input as one additional writer, not the whole surface.
  settingsPolicyChildren = rowsFrom (row: "${policy.key row} lists the exact omitted normalized fields") (row: let
    children = lib.filter (writer:
      lib.any (path: builtins.length path == 3 && lib.take 2 path == ["ai" "settings"])
      (writer.inputOptions or [])) (row.additionalWriters or []);
  in
    children
    == lib.optional (row.ecosystem == "kimchi") {
      inputOptions = [["ai" "settings" "inference"]];
      primitive = "notApplicable";
      reason = "kimchi's surfaceSupport.settings.fields does not consume this normalized setting.";
    }) (lib.filter (row: row.surface == "settings") policy.rows);
  caseMode = case: case.mode or "devenv";
  warningPath = case: case.path ++ (case.gapPath or case.suffix or []);
  caseName = outcome: case: "${case.runtime}/${caseMode case}/${lib.showOption (warningPath case)}: ${case.scenario or outcome}";
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
    # Dynamic reasons pin the expected message for the fixture rather than
    # calling the same formatter used by the warning producer.
    reason = case.reason or gap.reason;
    needle = expectedMessage (case
      // {
        inherit mode reason;
        path = warningPath case;
      });
    present = builtins.elem needle;
    enabled = harness.setEnable case.runtime true;
    evaluation = evalConfig mode (lib.recursiveUpdate enabled input);
    messages = evaluation.warnings;
  in
    builtins.seq gap (
      (
        if case.onlyWarning or false
        then messages == [needle]
        else present messages
      )
      && (!(case.checkEmpty or true) || !present emptyCaseWarnings.${mode}.${case.runtime})
      && (!(case.checkDisabled or true) || evaluate mode input == [])
    );
  kiroManualPriorityRows = mode: let
    enabled = harness.setEnable "kiro" true;
    check = ai: evaluate mode (lib.recursiveUpdate enabled {inherit ai;}) == [];
    root = inclusion: {
      inherit inclusion;
      text = "root";
    };
  in {
    "always wins over manual in the shared inclusion list" = check {rules.probe = root ["always" "manual"];};
    "native always replaces the manual shared rule of the same name" = check {
      kiro.rules.probe = {
        inclusion = "always";
        text = "native";
      };
      rules.probe = root ["manual"];
    };
  };
  # config/ai-delivery-facts.nix is pure `{lib}` data, so it lists the
  # runtimes with a native agent layer by name. The record is the source of
  # truth: `native.agents` must be an agents row's input exactly when the
  # runtime's record has `agentNativeType`.
  nativeAgentsListed = lib.all (row:
    builtins.elem ["ai" row.ecosystem "native" "agents"] (row.inputOptions or [])
    == (records.${row.ecosystem} ? agentNativeType))
  (lib.filter (row: row.surface == "agents") policy.rows);
  deliveryWarnings = import ../../lib/ai/delivery-warnings.nix {inherit lib;};
  mcpReasons = {
    http = "HTTP MCP entries use url; this stdio field is not rendered.";
    stdio = "This HTTP MCP field is not rendered for stdio.";
  };
  # The merged MCP type does not admit these transport/payload combinations.
  # Call the real warning reader with its module-derived shared surfaces and
  # only the conflicting payload populated (including empty map values).
  mcpFieldRows = let
    http.url = "https://example.invalid";
    stdio.command = "probe";
    warnings = enable: fixture:
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
    warns = reason: field: fixture:
      warnings true fixture
      == [
        (expectedMessage {
          inherit reason;
          mode = "devenv";
          path = ["ai" "claude" "mcpServers" "probe" field];
          runtime = "claude";
        })
      ];
  in {
    "HTTP identifies the ignored command only when enabled" = let
      fixture = http // stdio;
    in
      warns mcpReasons.http "command" fixture && warnings false fixture == [];
    "HTTP warns about env even when the variable value is empty" = warns mcpReasons.http "env" (http // {env.PROBE = "";});
    "stdio is quiet without a conflicting HTTP payload" = warnings true stdio == [];
    "stdio warns about headers even when the header value is empty" = warns mcpReasons.stdio "headers" (stdio // {headers.Authorization = "";});
  };
  # Kiro reads tool policy only from permission rules under ~/.kiro, which a
  # devenv shell neither writes nor reaches through a root of its own. Home
  # Manager declares the options that feed those rules; devenv declares none
  # of them and warns on the shared surface through `surfaceSupport`.
  kiroTrustChecks = let
    enable = harness.setEnable "kiro" true;
    devenv = input: harness.evalDevenv (lib.recursiveUpdate enable input);
    readWarnings = input: (devenv input).config.warnings;
    rejectsUnknown = path: value:
      !lib.hasAttrByPath path (devenv {}).options
      && rejectsChange readWarnings {
        valid = {};
        invalid = lib.setAttrByPath path value;
        expected = [];
      };
  in
    checkRows "Kiro tool trust" {
      # An option declared but ignored on devenv leaves a setting that looks
      # configured. Prove each option is absent and rejected as an unknown input.
      "devenv rejects ai.kiro.cli.trustedMcpTools as unknown" = rejectsUnknown ["ai" "kiro" "cli" "trustedMcpTools"] ["@probe"];
      "devenv rejects ai.kiro.permissions as unknown" = rejectsUnknown ["ai" "kiro" "permissions"] sample.permissions;
      # The Kiro owner checks the rendered permissions.yaml; check silence here.
      "hm does not warn about trustedMcpTools" = let
        result = evalConfig "hm" (lib.recursiveUpdate enable {ai.kiro.cli.trustedMcpTools = ["@probe"];});
      in
        !contains "does not deliver" result.warnings;
    };
in {
  imports = [./runtime.nix];
  checks = {
    ai-warnings-kiro-tool-trust = harness.mkTest "ai-warnings-kiro-tool-trust" kiroTrustChecks;
    ai-warnings-delivery = harness.mkTest "ai-warnings-delivery" (
      checkRows "delivery warnings" {
        "conditional declarations reach at least one backend" = declarationsCovered;
        "conditional gaps have a witness on each active backend" = conditionalCovered;
        "native agents are inventoried exactly where an agentNativeType is declared" = nativeAgentsListed;
      }
      && checkRows "policy-only absences" policyOnlyRows
      && checkRows "supported inputs" (rowsFrom
        (caseName "delivery must not warn about the supported request")
        quietCase
        quietCases)
      && checkRows "shared warning coverage" (rowsFrom
        (caseName "a populated unsupported input should name the dropped option, but empty or disabled should not warn")
        casePass
        gapCases)
      && checkRows "conditional and native warnings" (rowsFrom
        (caseName "only a populated, enabled request should warn with the specific loss reason")
        casePass
        (lib.filter (case: !(case.coverageOnly or false)) cases))
      && checkRows "policy settings inventory" settingsPolicyChildren
      && checkRows "Claude MCP transport warnings" mcpFieldRows
      && checkRows "devenv Kiro rule warnings" (kiroManualPriorityRows "devenv")
      && lib.assertMsg portableEventSilent "Claude delivers the portable PermissionRequest event"
    );
    ai-warnings-delivery-input-options = harness.mkTest "ai-warnings-delivery-input-options" inputsDeclared;
    ai-warnings-kiro-hook-prompts = harness.mkTest "ai-warnings-kiro-hook-prompts" (
      lib.all (mode: let
        warningsFor = enabled: hook:
          evaluate mode {
            ai.kiro = {
              cli.enable = enabled;
              hooks.probe = hook // {trigger = "UserPromptSubmit";};
            };
          };
        agent.action = {
          prompt.text = "probe";
          type = "agent";
        };
        command.action.command = "true";
        withActionField = hook: extra: lib.recursiveUpdate hook {action = extra;};
        warns = field: reason: hook:
          warningsFor true hook
          == ["ai.kiro.hooks.probe.${field} is set but ${mode} does not deliver it to kiro (reason: ${reason})"];
        ignoredPayload = "The selected action.type uses the other action payload.";
      in
        checkRows "${mode} Kiro hook warnings" {
          "agent action alone is quiet" = warningsFor true agent == [];
          "agent action ignores a command only when enabled" = let
            hook = withActionField agent {command = "true";};
          in
            warns "action.command" ignoredPayload hook && warningsFor false hook == [];
          "agent action ignores a timeout" = warns "timeout" "Agent hook actions have no subprocess timeout." (agent // {timeout = 1;});
          "command action alone is quiet" = warningsFor true command == [];
          "command action ignores a prompt" = warns "action.prompt" ignoredPayload (withActionField command {prompt.text = "probe";});
        })
      ["devenv" "hm"]
    );
    ai-warnings-kiro-proxy-instance-package-null = harness.mkTest "ai-warnings-kiro-proxy-instance-package-null" (
      lib.all (mode: let
        warnings = proxy:
          evaluate mode {
            ai = {
              airlock.instances.main = {};
              kiro.cli = {
                enable = true;
                package = null;
              };
              inherit proxy;
            };
          };
        warning = "ai.kiro.cli.package is null, so these settings are inert (they need the managed Kiro wrapper; the system binary runs without them): ai.proxy / ai.kiro.proxy. Unset them or set ai.kiro.cli.package.";
      in
        checkRows "${mode} Kiro proxy without a managed wrapper" {
          "an instance-only request names the ignored proxy option" = builtins.elem warning (warnings {instance = "main";});
          "no proxy request does not claim the wrapper ignored it" = !(contains "ai.proxy / ai.kiro.proxy" (warnings {}));
        })
      policy.modes
    );
    # A context or rule unit whose file is switched off (`enable =
    # false`) or replaced with the consumer's own bytes warns, naming the
    # unit, the file option that dropped it and a per-runtime way to withhold
    # it; the warning is what makes the drop visible. Withholding the unit or
    # having nothing to carry is quiet.
    ai-warnings-switched-off-files = harness.mkTest "ai-warnings-switched-off-files" (
      let
        enabled = runtimes: lib.foldl' lib.recursiveUpdate {} (map (runtime: harness.setEnable runtime true) runtimes);
        warnings = mode: runtimes: ai: evaluate mode (lib.recursiveUpdate (enabled runtimes) {inherit ai;});
        override = mode: runtimes: ai: owner: file: entry:
          warnings mode runtimes (lib.recursiveUpdate ai (lib.setAttrByPath [owner "files" file] entry));
        document = {
          context.text = "CTX";
          rules.probe.text = "RULE";
        };
        scoped = {
          matcher = ["src/**"];
          text = "SCOPED";
        };
        off.enable = false;
        replacement.content.text = "MINE";

        # An override can come from any participant in the shared AGENTS.md;
        # every participant whose content was lost must get its own remedy.
        agents = owner: entry: override "devenv" ["codex" "copilot" "kimchi" "kiro"] document owner "AGENTS.md" entry;
        sharedCodexOff = agents "codex" off;
        sharedOff = agents "kiro" off;
        sharedReplaced = agents "kiro" replacement;
        shared =
          rowsFrom (case: "shared AGENTS.md warns about lost context and rules for ${case.runtime}") (case: let
            ruleRemedy = "${case.rules}.probe.enable = false";
            contextRemedy = "${case.normalizedContext} = lib.mkForce null";
            reports = messages: file: cause:
              drop messages "ai.context" file cause contextRemedy
              && drop messages "ai.rules.probe" file cause ruleRemedy;
          in
            reports sharedCodexOff ''ai.codex.files."AGENTS.md"'' switchedOff
            && reports sharedOff ''ai.kiro.files."AGENTS.md"'' switchedOff
            && reports sharedReplaced ''ai.kiro.files."AGENTS.md"'' replaced)
          [
            {
              normalizedContext = "ai.codex.normalized.context";
              rules = "ai.codex.rules";
              runtime = "codex";
            }
            {
              normalizedContext = "ai.kimchi.normalized.context";
              rules = "ai.kimchi.rules";
              runtime = "kimchi";
            }
            {
              normalizedContext = "ai.kiro.normalized.context";
              rules = "ai.kiro.rules";
              runtime = "kiro";
            }
          ];

        # Copilot carries both context inputs in one file; its rules are separate.
        copilot = override "devenv" ["copilot"] (document // {copilot.github.context.text = "COPILOT-CTX";}) "copilot" ".github/copilot-instructions.md";
        copilotOff = copilot off;
        copilotReplaced = copilot replacement;
        copilotContextFile = ''ai.copilot.files.".github/copilot-instructions.md"'';
        copilotContextRemedy = "ai.copilot.github.normalized.context = lib.mkForce null";
        copilotRows = rowsFrom (unit: "Copilot names ${unit} when its instructions file drops it") (unit:
          drop copilotOff unit copilotContextFile switchedOff copilotContextRemedy
          && drop copilotReplaced unit copilotContextFile replaced copilotContextRemedy)
        ["ai.context" "ai.copilot.github.context"];

        codexHome = ai: override "hm" ["codex"] ai "codex" ".codex/AGENTS.md";
        codexHomeFile = ''ai.codex.files.".codex/AGENTS.md"'';
        codexHomeOff =
          codexHome {
            inherit (document) rules;
            codex.rules.local.text = "LOCAL";
          }
          off;
        codexProject = ai: override "devenv" ["codex"] ai "codex" "AGENTS.md";
        codexProjectFile = ''ai.codex.files."AGENTS.md"'';
        codexProjectReplaced = codexProject document replacement;
        codexRuleRemedy = "ai.codex.rules.probe.enable = false";
        claudeRule = mode: override mode ["claude"] {inherit (document) rules;} "claude" ".claude/rules/probe.md";
        claudeRuleFile = ''ai.claude.files.".claude/rules/probe.md"'';
        claudeRuleRemedy = "ai.claude.rules.probe.enable = false";
        steeringOff = override "devenv" ["kiro"] {kiro.rules = {inherit scoped;};} "kiro" ".kiro/steering/scoped.md" off;
        withheld = codexProject (document
          // {
            codex = {
              normalized.context = lib.mkForce null;
              rules.probe.enable = false;
            };
          })
        off;
        ordinary = mode: warnings mode ["claude" "codex" "copilot" "kimchi" "kiro"] (lib.recursiveUpdate document {rules = {inherit scoped;};});
        switchedOff = ".enable = false switches off";
        replaced = ".content replaces";
        drop = messages: unit: file: cause: remedy:
          lib.any (message:
            lib.hasInfix "${unit} is set but" message
            && lib.hasInfix "${file}${cause}" message
            && lib.hasInfix remedy message)
          messages;
        noDrop = messages: !(contains "the file that carries it" messages);
      in
        checkRows "file-drop warnings" (shared
          // copilotRows
          // {
            "Claude Home Manager names the disabled rule file and its remedy" = drop (claudeRule "hm" off) "ai.rules.probe" claudeRuleFile switchedOff claudeRuleRemedy;
            "Claude Home Manager symlink changes delivery method, not the rule body" = noDrop (claudeRule "hm" {method = "symlink";});
            "Claude devenv source override replaces rather than retaining the rule body" = drop (claudeRule "devenv" {content.source = pkgs.writeText "mine" "MINE";}) "ai.rules.probe" claudeRuleFile replaced claudeRuleRemedy;
            "Codex Home Manager names a disabled runtime rule at the runtime input" = drop codexHomeOff "ai.codex.rules.local" codexHomeFile switchedOff "ai.codex.rules.local.enable = false";
            "Codex Home Manager names a disabled shared rule at the shared input" = drop codexHomeOff "ai.rules.probe" codexHomeFile switchedOff codexRuleRemedy;
            "Codex Home Manager warns when its own AGENTS.md is replaced" = drop (codexHome {inherit (document) rules;} replacement) "ai.rules.probe" codexHomeFile replaced codexRuleRemedy;
            "Codex devenv disabling an unused file is quiet" = noDrop (codexProject {} off);
            "Codex devenv replacing an unused file is quiet" = noDrop (codexProject {} replacement);
            "Codex devenv replacing the only shared AGENTS.md warns about both inputs without claiming it was switched off" =
              drop codexProjectReplaced "ai.context" codexProjectFile replaced "ai.codex.normalized.context = lib.mkForce null"
              && drop codexProjectReplaced "ai.rules.probe" codexProjectFile replaced codexRuleRemedy
              && !(contains "switches off" codexProjectReplaced);
            "Codex devenv withholding the units is quiet even if their file is disabled" = noDrop withheld;
            "Copilot context file overrides leave the separate rule file alone" = !(contains "ai.rules.probe is set but devenv does not deliver it to copilot" (copilotOff ++ copilotReplaced));
            "Copilot is unaffected by another runtime's AGENTS.md override" = !(contains "does not deliver it to copilot" (sharedOff ++ sharedCodexOff ++ sharedReplaced));
            "Kiro devenv names the scoped steering file and per-rule remedy" = drop steeringOff "ai.kiro.rules.scoped" ''ai.kiro.files.".kiro/steering/scoped.md"'' switchedOff "ai.kiro.rules.scoped.enable = false";
            "devenv generated content is not mistaken for a final override" = noDrop (ordinary "devenv");
            "hm generated content is not mistaken for a final override" = noDrop (ordinary "hm");
          })
    );

    ai-warnings-tombstones = harness.mkTest "ai-warnings-tombstones" (
      let
        quiet = runtime: ai:
          evaluate "hm" (lib.recursiveUpdate (harness.setEnable runtime true) {inherit ai;}) == [];
      in
        checkRows "withheld inputs do not warn" {
          "Copilot's runtime tombstone suppresses the unsupported shared rule of that name" = quiet "copilot" {
            copilot.github.rules.probe.enable = false;
            rules.probe.text = "probe";
          };
          "Copilot's unsupported context is quiet when explicitly empty" = quiet "copilot" {copilot.github.context.text = "";};
          "Kimchi is quiet for a shared rule already disabled at the root" = quiet "kimchi" {rules.probe.enable = false;};
        }
    );
  };
}
