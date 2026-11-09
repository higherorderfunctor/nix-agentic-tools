let
  delegateKinds = ["external" "subagent" "workflow"];
in {
  inherit delegateKinds;
  familyDefaults = {
    cost = 3;
    trial = true;
  };
  kinds = delegateKinds ++ ["introspect" "usage"];
  tiers = ["frontier" "strong" "mid" "small"];
}
