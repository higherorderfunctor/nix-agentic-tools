{
  facetOwner,
  repoPath,
  ...
}: {
  documentation.genericDescriptions = {
    cliproxyapi = "OpenAI-compatible proxy for AI CLI subscriptions and APIs";
  };
  fragments.categories.cliproxyapi = {
    scopes = ["packages/${facetOwner}/**"];
    sources = [
      {
        dir = facetOwner;
        location = "package";
        name = "cliproxyapi-extraction";
      }
      {
        dir = facetOwner;
        location = "package";
        name = "cliproxyapi-key-allowlist";
      }
      {
        dir = facetOwner;
        location = "package";
        name = "cliproxyapi-settings";
      }
    ];
  };
  update.targets = {
    cliproxyapi = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/generic/cliproxyapi/package.nix)];};
    cliproxyapi-z-ai-docs = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/docs/cliproxyapi-z-ai-docs/package.nix)];};
  };
}
