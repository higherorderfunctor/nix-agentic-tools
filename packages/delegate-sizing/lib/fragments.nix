{
  fragmentsLib,
  repoPath,
  ...
}: {
  skill-routing = fragmentsLib.mkFragment {
    description = "Delegate model and effort sizing rule";
    priority = 10;
    source = repoPath ../fragments/skill-routing.md;
    text = (import ../router.nix).delegate-sizing-router.text;
  };
}
