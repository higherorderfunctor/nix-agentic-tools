{
  facetOwner,
  repoPath,
  ...
}: {
  documentation.genericDescriptions = {
    cliproxyapi = "OpenAI-compatible proxy for AI CLI subscriptions and APIs";
    cpa-gate = "Caddy with an optional client-key and exact-model gate for CLIProxyAPI";
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
        name = "cliproxyapi-front-gate";
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
  };
}
