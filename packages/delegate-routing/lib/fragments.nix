{
  fragmentsLib,
  repoPath,
  ...
}: {
  skill-routing = fragmentsLib.mkFragment {
    description = "Per-delegation skill load and the source for steering its rules";
    priority = 10;
    source = repoPath ../fragments/load-delegate-routing.md;
    text = builtins.readFile ../fragments/load-delegate-routing.md;
  };
}
