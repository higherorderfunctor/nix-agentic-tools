# State review is distinct from measured patchability. The canary proves every
# patchable feature whose vendor state still restricts availability.
{
  check = {
    extracted,
    lib,
    rows,
  }: let
    states = extracted.rolloutStates;
    names = lib.unique (extracted.rolloutFeatures ++ builtins.attrNames rows);
    oldState = name:
      if rows ? ${name}
      then rows.${name}.state
      else "MISSING REVIEW";
    newState = name: states.${name} or "MISSING FEATURE";
    failure = name: "rollout ${name}: old ${builtins.toJSON (oldState name)} -> new ${builtins.toJSON (newState name)}";
  in {
    failures = map failure (lib.filter (name:
      !(rows ? ${name}) || !(states ? ${name}) || rows.${name}.state != states.${name})
    names);
  };

  needsPatch = state: let
    unrestricted = key: fallback: let
      value = state.${key} or null;
    in
      value == null || value == fallback;
  in
    !(state.treatment_percent == 100 && unrestricted "segment" "all" && unrestricted "channel" "stable");
}
