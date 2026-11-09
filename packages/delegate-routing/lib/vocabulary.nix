let
  delegateKinds = ["external" "subagent" "workflow"];
in {
  inherit delegateKinds;
  familyDefaults = {cost = 3;};
  kinds = delegateKinds ++ ["introspect" "usage"];
  tiers = ["frontier" "strong" "mid" "small"];
}
