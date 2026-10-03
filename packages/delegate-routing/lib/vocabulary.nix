let
  delegateKinds = ["external" "subagent" "workflow"];
in {
  inherit delegateKinds;
  kinds = delegateKinds ++ ["introspect" "usage"];
  tiers = ["frontier" "strong" "mid" "small"];
}
