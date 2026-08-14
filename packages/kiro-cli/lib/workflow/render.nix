# Render an authored workflow (./types.nix shape) to the engine's wire JSON.
#
# This is where the authored/wire divergence documented in ./types.nix is
# paid back: tags become `type` discriminators, the two stop forms become the
# `stopCondition` / `stopWhen` fields, a jsonPath segment list is joined, and
# a tagged watcher splits into `handler` + `config`.
#
# ── Null pruning ────────────────────────────────────────────────────────────
#
# Optional fields default to `null` in the option types and are DROPPED here
# rather than emitted as JSON null. That matters: the engine's Zod treats a
# present-but-null optional as a type error, not as absent.
#
# ── DELIVERY HAZARD: never symlink the result ───────────────────────────────
#
# A `.workflow.json` that is a SYMLINK into the Nix store is listed by
# discovery and then REFUSES TO LAUNCH. The two paths disagree by
# construction: discovery stats the file (following symlinks), while the
# launch path resolves it through realpath and requires the result to sit
# inside a workspace root — and `/nix/store/...` never does.
#
# So `home.file.<...>.text`, which symlinks into the store, is the WRONG
# delivery mechanism for a workflow definition even though it is the obvious
# one. Deliver by COPYING at activation, the way this package already writes
# a private mcp.json. `toJSON` returns a string precisely so the caller
# chooses delivery; no `writeText` helper is offered here, because handing
# one out is handing out the hazard.
#
# Code-read at KAS 2.18.0, not measured — probe P-01 settles it.
{lib}: let
  inherit (builtins) attrNames head;
  inherit (lib) concatStringsSep filterAttrs optionalAttrs;

  # Drop nulls and empty collections. `captureOutput = false` must survive,
  # so this tests for null explicitly rather than for truthiness.
  prune = filterAttrs (_: v: v != null);

  tagOf = attrs: head (attrNames attrs);

  renderFileCheck = fc: {
    inherit (fc) path value;
    jsonPath = concatStringsSep "." fc.jsonPath;
  };

  renderStopCondition = c:
    prune {
      inherit (c) containsText completionSignal;
      fileCheck =
        if c.fileCheck == null
        then null
        else renderFileCheck c.fileCheck;
    };

  renderStopWhen = w:
    if w ? watchTerminal
    then "${w.watchTerminal}.terminal"
    else "{{${w.contains.template}}} contains ${w.contains.text}";

  # `stop` is one tag over the two forms, so at most one of these two wire
  # fields can ever be produced — the engine's "not both" rule is satisfied
  # structurally rather than checked.
  renderStop = stop:
    if stop == null
    then {}
    else if stop ? condition
    then {stopCondition = renderStopCondition stop.condition;}
    else {stopWhen = renderStopWhen stop.when;};

  renderWatcher = w: let
    handler = tagOf w;
  in {
    inherit handler;
    config = prune w.${handler};
  };

  renderNode = n: let
    tag = tagOf n;
    v = n.${tag};
  in
    if tag == "step"
    then
      {
        type = "step";
        inherit (v) agent id prompt;
      }
      // prune {
        inherit (v) captureOutput effortLevel modelId;
        completion =
          if v.completion == null
          then null
          else renderStopCondition v.completion;
      }
      // optionalAttrs (v.artifacts != {}) {inherit (v) artifacts;}
    else if tag == "sequence"
    then {
      type = "sequence";
      inherit (v) id;
      steps = map renderNode v.steps;
    }
    else if tag == "repeat"
    then
      {
        type = "repeat";
        inherit (v) id maxIterations onMaxIterations;
        steps = map renderNode v.steps;
      }
      // renderStop v.stop
    else if tag == "parallel"
    then {
      type = "parallel";
      inherit (v) id joinPolicy;
      branches = map renderNode v.branches;
    }
    else if tag == "watch"
    then
      {
        type = "watch";
        inherit (v) id;
      }
      // renderWatcher v.watcher
      // prune {inherit (v) idleTimeoutSec;}
    else throw "kiro workflow: unknown node tag '${tag}' (this is unreachable through the option type)";

  renderWorkflow = w:
    {
      inherit (w) name;
      steps = map renderNode w.steps;
    }
    // prune {inherit (w) description effortLevel modelId;}
    // optionalAttrs (w.inputs != {}) {inherit (w) inputs;};
in rec {
  inherit renderNode renderStopCondition renderStopWhen renderWorkflow;

  # Wire-shape attrset. Feed to builtins.toJSON, or compare against a
  # `builtins.fromJSON` of a real definition for a round-trip test.
  toAttrs = renderWorkflow;

  # The serializer. `toJSON` produces one line; the engine's own normalized
  # copy is 2-space indented, but that is the MACHINE's copy of an
  # already-parsed object and is not a constraint on the authored file.
  toJSON = w: builtins.toJSON (renderWorkflow w);

  # Filename the definition must be given. The stem is what names the recipe
  # to the user; `workflow.name` is never compared to it for a workspace
  # recipe, so the two silently diverging is a real (if cosmetic) trap.
  fileNameFor = stem: "${stem}.workflow.json";

  # Render with the stem asserted against `name`. Use this rather than
  # `toJSON` when you control the filename, which is the normal case for a
  # generator.
  toJSONAs = stem: w:
    if stem != w.name
    then
      builtins.trace
      ("kiro workflow: filename stem '${stem}' differs from workflow.name '${w.name}'. "
        + "The engine names the recipe from the STEM and never compares the two, so the run "
        + "will be labelled '${w.name}' while the recipe reads as '${stem}'.")
      (toJSON w)
    else toJSON w;
}
