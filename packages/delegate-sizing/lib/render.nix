{
  lib,
  runtime,
  extraRuntimes ? [],
  manualExternalDelegates ? [],
  presets,
  settings ? presets,
}: let
  # Read model decisions and runtime routes before selecting table candidates.
  models = import ./models.nix;
  # Public-catalog ids from the kiro-cli extractor; the skill still requires the live list because account availability differs.
  kiroModels = (builtins.fromJSON (builtins.readFile ../../kiro-cli/extracted.json)).models;
  firstParty = {
    claude = ["anthropic"];
    codex = ["openai"];
    kiro = ["anthropic" "openai"];
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
    then "via ${target} launch block: ${id}"
    else if runtime == "claude"
    then "Agent/Workflow `model`: ${id}"
    else if runtime == "codex"
    then "`collaboration.spawn_agent` model: ${id}"
    else "workflow step `modelId`: ${id}";
  # Emit tiers in capability order, with first-party rows before external rows.
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
  # Emit only configured blocks; manual-only instructions follow the main table.
  block = target: key: title:
    lib.optionalString (settings.${target}.${key}.enable or true)
    "#### ${target} ${title}\n\n${lib.removeSuffix "\n" settings.${target}.${key}.text}\n";
  joinBlocks = blocks: lib.concatStringsSep "\n" (builtins.filter (text: text != "") blocks);
  runtimeBlock = target:
    "### ${target} runtime\n\n"
    + joinBlocks [
      (block target "delegateTools" "delegate tools")
      (block target "introspectModels" "models and effort")
      (block target "checkUsage" "usage")
      (lib.optionalString (target != runtime) (block target "launch" "launch"))
    ];
  allModels = lib.concatMap (name: builtins.attrValues models.${name}) ["frontier" "strong" "mid" "small"];
  manual = target: let
    known = builtins.filter (available target) allModels;
    ids = lib.concatMapStringsSep "; " (model: "${model.name}: `${modelId target model}`") known;
    purpose = {
      claude = "For a Claude external delegate, follow the matching model row in the main table when present.";
      codex = "For a Codex external delegate, follow the matching model row in the main table when present.";
      kiro = "Follow the Luna row in the main table when present.";
    };
  in ''
    ### ${target}

    Not a candidate for auto-selection; use only when the user names it.

    ${purpose.${target}}

    Slug spelling: ${ids}.
    Confirm availability in the live catalog before launching.

    ${joinBlocks [(block target "launch" "launch") (block target "introspectModels" "models and effort")]}
  '';
in ''
  ---
  name: delegate-sizing
  description: Before calling a subagent, spawning a delegate, or building a workflow, size the model and effort for the task and available runtime pools.
  ---

  ${builtins.readFile ./rules.md}
  Use this skill for delegates and workflow nodes. Size each stage separately.
  Set effort every time; harness defaults differ. If a model has no effort
  control, record effort as not applicable. State the selected model and effort
  in the brief and apply them through the controls below.

  A harness without a per-delegate model or effort control (Copilot today) does the work inline at the session's sizing, or hands it to an external delegate.
  Sizing is a budget decision, not a rigor decision: a cheaper delegate still owes the same evidence, and a task that cannot meet the bar on the cheap model is sized up, not relaxed.

  If one model clearly stands out for the work, take it regardless of usage
  unless that pool is exhausted. If candidates are close, take the pool with
  more remaining. Check usage with the runtime's command. If no usage check is
  available, prefer the other pool among otherwise close candidates.

  ## delegate sizing

  OpenAI writer order: Sol/medium, then Luna/high, then Terra/medium.
  ${lib.optionalString (extras != [] || manualExternalDelegates != []) "For an external delegate, use its launch block in a shell step."}

  ${joinBlocks (map tier ["frontier" "strong" "mid" "small"])}
  ${lib.concatMapStringsSep "\n" runtimeBlock runtimes}
  ## procedure

  1. Write the rubric from operator-approved examples and give it to the writer and judge.
  2. Before assigning a change, decide whether to extend an existing abstraction or replace it.
  3. Set a hard cap before starting: three writer/reviewer rounds by default.
  4. Classify each failure: conceptual, missing evidence, execution, unclear standard or done.
     Step up the model for conceptual failures; fetch missing evidence; repair execution failures.
     Clarify unclear standards with the operator. Stop when done.
  5. Judge correctness and readability separately. Check calibration, actionability, precision,
     recall and stopping. Return accept, revise or insufficient evidence with a localized reason.
  6. Escalate after two rounds with the same defect. Change the brief; do not reset the cap.
     At the cap, return the artifact, remaining defects and needed decision to the operator.
  7. For two reviewers, take the union of their findings and adjudicate each one.
     Do not intersect findings or use cross-vendor panels. Sol must not be the sole judge.

  ${lib.optionalString (manualExternalDelegates != [])
    ("## manual-only external delegate sizing\n\n" + lib.concatMapStringsSep "\n" manual (lib.unique manualExternalDelegates))}
''
