{lib}: let
  exactKeys = keys: value:
    builtins.isAttrs value
    && builtins.attrNames value == lib.sort builtins.lessThan keys;
  nonemptyString = value: builtins.isString value && value != "";
  nullableString = value: value == null || nonemptyString value;
  results = ["supported" "unknown" "unsupported"];
  resultRecord = value:
    exactKeys ["evidence" "result"] value
    && builtins.elem value.result results
    && nonemptyString value.evidence;
  depthRecord = value:
    exactKeys ["evidence" "result" "value"] value
    && resultRecord (builtins.removeAttrs value ["value"])
    && (value.value == null || (builtins.isInt value.value && value.value >= 0))
    && (value.result != "supported" || builtins.isInt value.value)
    && (value.result != "unknown" || value.value == null);
  pins = value:
    exactKeys ["effort" "model"] value
    && (value.effort == null || builtins.isString value.effort)
    && (value.model == null || builtins.isString value.model);
  ordinaryCapabilities = [
    "available"
    "linkedWorktreeCommit"
    "pinsEffort"
    "pinsModel"
    "runsOwnSubagents"
  ];
  validate = value: let
    publishable = text:
      nonemptyString text
      && builtins.match ".*(^|[^A-Za-z0-9_.$}-])(/nix/store/|/home/|/Users/|/tmp/|private/).*" text == null;
  in
    exactKeys [
      "capabilities"
      "context"
      "date"
      "mode"
      "observed"
      "replay"
      "requested"
      "runtime"
      "runtimeVersion"
      "source"
      "technique"
    ]
    value
    && nonemptyString value.runtime
    && nullableString value.runtimeVersion
    && builtins.isString value.date
    && builtins.match "[0-9]{4}-[0-9]{2}-[0-9]{2}" value.date != null
    && builtins.elem value.mode ["acp" "headless" "interactive"]
    && nonemptyString value.technique
    && builtins.isList value.replay
    && value.replay != []
    && builtins.all publishable value.replay
    && pins value.requested
    && pins value.observed
    && publishable value.context
    && publishable value.source
    && exactKeys (ordinaryCapabilities ++ ["nestingDepth"]) value.capabilities
    && builtins.all (name: resultRecord value.capabilities.${name}) ordinaryCapabilities
    && depthRecord value.capabilities.nestingDepth
    && builtins.all (record: publishable record.evidence) (builtins.attrValues value.capabilities);

  directory = ../fixtures/capabilities;
  entries = builtins.readDir directory;
  fixtureNames = builtins.filter (name: lib.hasSuffix ".json" name) (builtins.attrNames entries);
  records = map (filename: let
    value = builtins.fromJSON (builtins.readFile (directory + "/${filename}"));
  in
    if entries.${filename} != "regular"
    then throw "delegate-routing capability observation ${filename}: expected a regular JSON file"
    else if !validate value
    then throw "delegate-routing capability observation ${filename}: invalid observation schema"
    else {inherit filename value;})
  fixtureNames;
  sameIdentity = left: right:
    left.runtime
    == right.runtime
    && left.technique == right.technique
    && left.mode == right.mode;
  checked = lib.foldl' (prior: record: let
    duplicate = lib.findFirst (other: sameIdentity other.value record.value) null prior;
  in
    if duplicate != null
    then throw "delegate-routing capability observations ${duplicate.filename} and ${record.filename}: duplicate runtime/technique/mode ${record.value.runtime}/${record.value.technique}/${record.value.mode}"
    else prior ++ [record]) []
  records;
  observations = builtins.deepSeq checked (map (record: record.value) checked);
  find = runtime: technique: mode:
    lib.findFirst (value: sameIdentity value {inherit runtime technique mode;}) null observations;
  header = observation: "${observation.runtime} ${
    if observation.runtimeVersion == null
    then "unknown"
    else observation.runtimeVersion
  }; ${observation.date}; ${observation.source}";
in {
  inherit find header observations validate;
}
