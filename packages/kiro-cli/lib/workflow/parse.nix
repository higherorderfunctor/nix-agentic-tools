# Import an engine-shaped `.workflow.json` into the authored shape.
#
# The inverse of ./render.nix. Two reasons this exists rather than the schema
# just accepting the wire shape directly:
#
#   1. It lets the Nix analyzer check definitions that ALREADY EXIST — the
#      hand-written ones under `.kiro/workflows/`, and the seven vendor
#      recipes inlined in the engine bundle, which are the highest-fidelity
#      conformance corpus available because the engine self-validates them at
#      module init.
#   2. `parse` then `render` must round-trip. That property is what proves the
#      authored/wire divergence is a faithful re-encoding rather than a
#      lossy one, and it is tested rather than asserted.
#
# This is a TOTAL function on well-formed input and throws loudly otherwise.
# It deliberately does NOT validate — feed the result through
# `analyze.assertValid` for that. Keeping the two apart means a malformed file
# produces a parse error naming the field, not a schema error naming a type.
{lib}: let
  inherit (builtins) hasAttr;
  inherit (lib) hasPrefix hasSuffix optionalAttrs removePrefix removeSuffix splitString;
  syntax = import ./syntax.nix {inherit lib;};

  # `stopWhen` has exactly two grammars and nothing else parses. Reproduced
  # from the engine's `parseStopWhen`, including the lexical rules that no
  # vendor document states.
  parseStopWhen = ctx: s:
    if hasPrefix "{{" s
    then let
      rest = removePrefix "{{" s;
    in
      if !(lib.hasInfix "}}" rest)
      then throw "kiro workflow: ${ctx}: stopWhen '${s}' opens '{{' and never closes it"
      else let
        parts = splitString "}}" rest;
        template = builtins.head parts;
        afterClose = lib.concatStringsSep "}}" (builtins.tail parts);
      in
        if !(hasPrefix " contains " afterClose)
        then throw "kiro workflow: ${ctx}: stopWhen '${s}' must have ' contains ' (exactly one space each side) after the template"
        else let
          text = removePrefix " contains " afterClose;
        in
          if text == ""
          then throw "kiro workflow: ${ctx}: stopWhen '${s}' has an empty literal after ' contains '"
          else {
            contains = {inherit template text;};
          }
    else if lib.hasInfix " contains " s
    then throw "kiro workflow: ${ctx}: stopWhen '${s}' has ' contains ' but its left side is not a '{{...}}' template at position 0"
    else if lib.hasInfix "{{" s || lib.hasInfix "}}" s
    then throw "kiro workflow: ${ctx}: stopWhen '${s}' places a template somewhere other than the very start"
    else if !(hasSuffix ".terminal" s)
    then throw "kiro workflow: ${ctx}: stopWhen '${s}' must be '<watchId>.terminal' or '{{expr}} contains <text>'"
    else let
      watchId = removeSuffix ".terminal" s;
    in
      if watchId == "" || lib.hasInfix "." watchId || syntax.hasJsWhitespace watchId
      then throw "kiro workflow: ${ctx}: stopWhen '${s}' has a watch id that is empty, dotted or contains whitespace"
      else {watchTerminal = watchId;};

  parseFileCheck = fc: {
    inherit (fc) path value;
    # The wire form is a '.'-separated property walk; the authored form is the
    # segment list that makes the JSONPath spelling unrepresentable.
    jsonPath = lib.filter (segment: segment != "") (splitString "." fc.jsonPath);
  };

  parseStopCondition = c:
    optionalAttrs (hasAttr "containsText" c) {inherit (c) containsText;}
    // optionalAttrs (hasAttr "completionSignal" c) {inherit (c) completionSignal;}
    // optionalAttrs (hasAttr "fileCheck" c) {fileCheck = parseFileCheck c.fileCheck;};

  parseNode = n:
    if !(hasAttr "type" n)
    then throw "kiro workflow: node is missing its `type` discriminator: ${builtins.toJSON n}"
    else if n.type == "step"
    then {
      step =
        {inherit (n) agent id prompt;}
        // optionalAttrs (hasAttr "artifacts" n) {inherit (n) artifacts;}
        // optionalAttrs (hasAttr "captureOutput" n) {inherit (n) captureOutput;}
        // optionalAttrs (hasAttr "modelId" n) {inherit (n) modelId;}
        // optionalAttrs (hasAttr "effortLevel" n) {inherit (n) effortLevel;}
        // optionalAttrs (hasAttr "completion" n) {completion = parseStopCondition n.completion;};
    }
    else if n.type == "sequence"
    then {
      sequence = {
        inherit (n) id;
        steps = map parseNode n.steps;
      };
    }
    else if n.type == "repeat"
    then {
      repeat =
        {
          inherit (n) id maxIterations onMaxIterations;
          steps = map parseNode n.steps;
        }
        // (
          if hasAttr "stopCondition" n && hasAttr "stopWhen" n
          then throw "kiro workflow: repeat '${n.id}' defines BOTH stopCondition and stopWhen"
          else if hasAttr "stopCondition" n
          then {stop.condition = parseStopCondition n.stopCondition;}
          else if hasAttr "stopWhen" n
          then {stop.when = parseStopWhen "repeat '${n.id}'" n.stopWhen;}
          else {}
        );
    }
    else if n.type == "parallel"
    then {
      parallel = {
        inherit (n) id joinPolicy;
        branches = map parseNode n.branches;
      };
    }
    else if n.type == "watch"
    then {
      watch =
        {
          inherit (n) id;
          watcher.${n.handler} = n.config or {};
        }
        // optionalAttrs (hasAttr "idleTimeoutSec" n) {inherit (n) idleTimeoutSec;};
    }
    else throw "kiro workflow: unknown node type '${n.type}' (legal: parallel, repeat, sequence, step, watch)";
in rec {
  inherit parseNode parseStopCondition parseStopWhen;

  # Wire attrset -> authored definition.
  #
  # `planRevision` is dropped rather than carried: the runner overwrites it
  # with 0 at creation, so it is machine state that happens to live in the
  # same file, and round-tripping it would reintroduce a field the authored
  # shape deliberately has no option for.
  fromAttrs = w:
    {
      inherit (w) name;
      steps = map parseNode w.steps;
      inputs = w.inputs or {};
    }
    // lib.filterAttrs (_: v: v != null) {
      description = w.description or null;
      modelId = w.modelId or null;
      effortLevel = w.effortLevel or null;
    };

  fromJSON = s: fromAttrs (builtins.fromJSON s);
  fromFile = p: fromAttrs (builtins.fromJSON (builtins.readFile p));
}
