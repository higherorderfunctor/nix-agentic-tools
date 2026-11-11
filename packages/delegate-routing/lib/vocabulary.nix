let
  delegateKinds = ["external" "subagent" "workflow"];
in {
  inherit delegateKinds;
  effortLevels = ["minimal" "low" "medium" "high" "xhigh" "max"];
  kinds = delegateKinds ++ ["introspect" "usage"];
  lowWaterMark = 0.5;
  tiers = ["frontier" "strong" "mid" "small"];
}
