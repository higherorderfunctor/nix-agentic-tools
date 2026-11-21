let
  delegateKinds = ["external" "subagent" "workflow"];
in {
  inherit delegateKinds;
  effortLevels = ["minimal" "low" "medium" "high" "xhigh" "max"];
  kinds = delegateKinds ++ ["introspect" "usage"];
  supportedRuntimes = ["claude" "codex" "kimchi" "kiro"];
  tiers = ["frontier" "strong" "mid" "small"];
}
