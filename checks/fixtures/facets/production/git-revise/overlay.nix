{packages, ...}: {
  claims = [
    ["ai" "gitReviseObserved"]
    ["ai" "gitTools" "git-revise"]
  ];
  overlay = _final: prev: {
    ai =
      prev.ai
      // {
        gitReviseObserved = "${prev.ai.seed}:${prev.ai.alpha}";
        gitTools = (prev.ai.gitTools or {}) // {inherit (packages) git-revise;};
      };
  };
}
