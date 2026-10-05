{
  fragmentsLib,
  repoPath,
  ...
}: {
  skill-routing = fragmentsLib.mkFragment {
    description = "Delegate model and effort sizing rule";
    priority = 10;
    source = repoPath ../fragments/load-delegate-routing.md;
    text = builtins.readFile ../fragments/load-delegate-routing.md;
  };
}
