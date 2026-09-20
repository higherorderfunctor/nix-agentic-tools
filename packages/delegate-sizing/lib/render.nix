{
  lib,
  runtime,
  extraRuntimes ? [],
  manualExternalDelegates ? [],
  settings ? import ./presets.nix,
}: let
  models = import ./models.nix;
  presets = import ./presets.nix;
  kiroModels = builtins.fromJSON (builtins.readFile ../../kiro-cli/models.json);
  firstParty = {
    claude = ["anthropic"];
    codex = ["openai"];
    kiro = ["anthropic" "openai"];
  };
  launchNames = {
    claude = "claude -p";
    codex = "codex exec";
    kiro = "kiro-cli chat";
  };
  # Manual-only wins if a consumer names the same runtime in both lists.
  extras = lib.subtractLists manualExternalDelegates (lib.unique extraRuntimes);
  runtimes = [runtime] ++ extras;
  available = target: model:
    model.ids ? ${target}
    && builtins.elem model.vendor firstParty.${target}
    && (target != "kiro" || builtins.elem model.ids.kiro kiroModels);
  targets = model: builtins.filter (target: available target model) runtimes;
  modelId = target: model:
    if target == "claude" && target != runtime
    then model.ids.claudeHeadless
    else model.ids.${target};
  reach = target: model: let
    id = "`${modelId target model}`";
  in
    if target != runtime
    then
      if settings.${target}.launch == false
      then "external ${target}: ${id} (launch instruction disabled)"
      else if settings.${target}.launch == presets.${target}.launch
      then "via `${launchNames.${target}}`: ${id} (see ${target} launch block)"
      else "via ${target} launch block: ${id}"
    else if runtime == "claude"
    then "Agent/Workflow `model`: ${id}"
    else if runtime == "codex"
    then "`collaboration.spawn_agent` model: ${id}"
    else "workflow step `modelId`: ${id}";
  cell = lib.replaceStrings ["|" "\n"] ["\\|" " "];
  row = model:
    "| "
    + lib.concatMapStringsSep " | " cell [
      "${model.name} (${model.vendor})"
      model.useFor
      model.avoidFor
      model.effort
      (lib.concatMapStringsSep "; " (target: reach target model) (targets model))
    ]
    + " |";
  tier = name: let
    candidates = builtins.filter (model: targets model != []) (builtins.attrValues models.${name});
    native =
      lib.concatMap
      (vendor: builtins.filter (model: available runtime model && model.vendor == vendor) candidates)
      firstParty.${runtime};
    external = builtins.filter (model: !(available runtime model)) candidates;
  in
    lib.optionalString (candidates != []) ''
      ### ${name}

      | Model | Use for | Avoid for | Effort (delegate) | How to reach |
      | --- | --- | --- | --- | --- |
      ${lib.concatMapStringsSep "\n" row (native ++ external)}
    '';
  block = target: key: title:
    lib.optionalString (settings.${target}.${key} != false) ''
      #### ${target} ${title}

      ${settings.${target}.${key}}
    '';
  runtimeBlock = target: ''
    ### ${target} runtime

    ${block target "delegateTools" "delegate tools"}
    ${block target "introspectModels" "models and effort"}
    ${block target "checkUsage" "usage"}
    ${lib.optionalString (target != runtime) (block target "launch" "launch")}
  '';
  allModels = lib.concatMap (name: builtins.attrValues models.${name}) ["frontier" "strong" "mid" "small"];
  manual = target: let
    known = builtins.filter (available target) allModels;
    ids = lib.concatMapStringsSep "; " (model: "${model.name}: `${modelId target model}`") known;
    purpose = {
      claude = "For user-requested Claude delegates, use the corresponding tier's model guidance above when present; manual inclusion adds no auto-selectable rows.";
      codex = "For user-requested Codex code writers and debug loops, use the corresponding tier's model guidance above when present; manual inclusion adds no auto-selectable rows.";
      kiro = "Employer credits: fixture probes only, pin Luna. Use the Luna row above when present; this section adds no implementation candidate.";
    };
  in ''
    ### ${target}

    Not a candidate for auto-selection; use only when the user names it.

    ${purpose.${target}}

    Slug spelling: ${ids}.
    Availability depends on the live runtime/account catalog; a listed spelling
    does not grant access. ${lib.optionalString (target == "kiro") "This Kiro account has no Astra or Fable."}

    ${block target "launch" "launch"}
    ${block target "introspectModels" "models and effort"}
  '';
in ''
  ---
  name: delegate-sizing
  description: Before calling a subagent, spawning a delegate, or building a workflow, size the model and effort for the task and available runtime pools.
  ---

  ${builtins.readFile ../fragments/skill-routing.md}
  Scope: delegates and workflow nodes. Interactive root selection stays with
  the operator. No task class is reserved for a vendor.

  If one model clearly stands out for the work type, take it regardless of usage
  unless that pool is exhausted. If candidates are close, take the pool with more
  remaining; check usage with the command in the runtime block. If no usage read
  is configured or available, report that gap and prefer the pool you are not
  currently in among otherwise close candidates.

  Effort is set explicitly every time because defaults differ per harness. When
  the model has no effort knob, record it as not applicable; never invent one.
  Name the selected pair and the task reason in the launch message, and apply
  them through the actual controls described below. Size each workflow stage
  separately; a follow-up message does not change a running delegate's pair.

  ## delegate sizing

  Tiers put both vendors next to each other, with first-party rows first and
  external routes marked by launch command. Rows appear only for reachable
  candidates. OpenAI writer order: Sol/medium, then Luna/high, then Terra/medium.
  For an external runtime, use its launch block in the host's Bash step;
  delegate-tools blocks describe controls inside that runtime.

  ${lib.concatMapStringsSep "\n" tier ["frontier" "strong" "mid" "small"]}
  ${lib.concatMapStringsSep "\n" runtimeBlock runtimes}
  ${lib.optionalString (manualExternalDelegates != []) ''
    ## manual-only external delegate sizing

    ${lib.concatMapStringsSep "\n" manual (lib.unique manualExternalDelegates)}
  ''}
  ## procedure

  1. Write the rubric first from operator-approved examples. For a change,
     decide whether to extend an existing abstraction or replace it before
     assigning implementation; give the writer that decision and its boundaries.
  2. Select model and effort for each bounded task. Prefer deterministic checks
     for checkable work. Judge correctness and readability separately, using
     acceptance calibration, actionability, precision, recall and stopping
     behavior. A judge returns accept, revise or insufficient evidence, with
     localized reasons and a minimal repair direction.
  3. Set a hard round cap before starting (default: three writer/reviewer
     rounds). Classify failures: conceptual means step up the model;
     evidence-missing means fetch the missing evidence; execution means repair
     the concrete tool or implementation failure; unclear-standard means clarify
     the rubric with the operator; done means stop. More effort does not repair
     missing evidence or an unclear standard.
  4. Escalate after two rounds with the same defect class; do not repeat an
     unchanged brief. At the cap, stop the loop and return the artifact, remaining
     defects and needed decision to the operator. Escalation never resets the cap.
  5. When two reviewers are warranted, UNION their findings and adjudicate;
     never intersect them. No cross-vendor panels. Use one strong judge at high
     for taste/architecture, and a cheap judge with written criteria and several
     samples for rubric-checkable work. Sol must never be the sole grader.
''
