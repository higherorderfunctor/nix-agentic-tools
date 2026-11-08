{
  fragmentsLib,
  repoPath,
  ...
}: {
  skill-routing = fragmentsLib.mkFragment {
    description = "Per-delegation skill load and steering changes to authoritative sources";
    priority = 10;
    source = repoPath ../fragments/load-delegate-routing.md;
    text = builtins.readFile ../fragments/load-delegate-routing.md;
  };
}
