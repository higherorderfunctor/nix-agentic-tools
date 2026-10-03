{
  facetOwner,
  repoPath,
  ...
}: {
  checks.cacheHitParity = {
    kimchi = {consumerPath = ["ai" "kimchi"];};
    kimchi-docs = {consumerPath = ["docs" "kimchi-docs"];};
    kimchi-login-vm = {
      consumerPath = ["ai" "devTools" "kimchi-login-vm"];
      platforms = import ./packages/ai/devTools/kimchi-login-vm/platforms.nix;
    };
  };
  documentation = {
    aiCliDescriptions.kimchi = "Kimchi CLI";
    devToolDescriptions.kimchi-login-vm = "Throwaway headless NixOS guest for Kimchi browser login testing (Linux only)";
    skillDescriptions.kimchi-docs = "Search the pinned Kimchi docs snapshot; enable via ai.programs.kimchi-docs.enable";
  };
  # kimchi: two-tree factory (config.json + harness/), runtime SOPS
  # credential, wrapProgram separator + flattenDotKeys gotchas.
  fragments.categories.kimchi = {
    scopes = [
      "packages/${facetOwner}/**"
    ];
    sources = [
      {
        location = "package";
        name = "kimchi-factory";
        dir = facetOwner;
      }
      {
        location = "package";
        name = "login-vm";
        dir = facetOwner;
      }
    ];
  };
  # The package update script refreshes the pinned Kimchi and pi extraction
  # sources, then regenerates extracted.json after every version bump.
  update.targets.kimchi = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/kimchi/package.nix)];};
  update.targets.kimchi-docs = {flags = ["--use-update-script"];};
}
