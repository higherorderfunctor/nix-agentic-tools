{
  facetOwner,
  repoPath,
  ...
}: {
  documentation.genericDescriptions.cliproxyapi = "OpenAI-compatible proxy for AI CLI subscriptions and APIs";
  # cliproxyapi: the extraction behind ai.proxy's typed instance options.
  fragments.categories.cliproxyapi = {
    scopes = ["packages/${facetOwner}/**"];
    sources = [
      {
        dir = facetOwner;
        location = "package";
        name = "cliproxyapi-extraction";
      }
    ];
  };
  update.targets.cliproxyapi = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/generic/cliproxyapi/package.nix)];};
}
