{
  facetOwner,
  repoPath,
  ...
}: {
  documentation.devToolDescriptions = {
    "codeql.codeql-<engine>" = "GitHub CodeQL CLI: `bare`, `full`, or one language's bundle (unfree, x86_64-linux, never published)";
    "codeql.codeql-extractor-nix" = "MIT Nix extractor and QL library for CodeQL (x86_64-linux)";
    "codeql.codeql-query" = "Local CodeQL query client with an optional per-database daemon";
  };
  fragments.categories.codeql = {
    scopes = ["packages/${facetOwner}/**"];
    sources = [
      {
        location = "package";
        name = "codeql";
        dir = facetOwner;
      }
      {
        location = "package";
        name = "customize";
        dir = facetOwner;
      }
    ];
  };
  # The engine target bumps all engines; the extractor has its own release target.
  update.targets.codeql-extractor-nix = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/devTools/codeql/codeql-extractor-nix/package.nix)];};
  update.targets.codeql-full = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/devTools/codeql/codeql-full/package.nix)];};
}
