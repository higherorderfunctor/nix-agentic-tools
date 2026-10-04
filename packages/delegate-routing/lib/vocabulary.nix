let
  delegateKinds = ["external" "subagent" "workflow"];
in {
  inherit delegateKinds;
  # Delegate sizing supports max; persisted runtime reasoning settings omit it.
  efforts = ["low" "medium" "high" "xhigh" "max"];
  kinds = delegateKinds ++ ["introspect" "usage"];
  tiers = ["frontier" "strong" "mid" "small"];
}
