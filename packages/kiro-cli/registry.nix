{
  facetOwner,
  repoPath,
  ...
}: {
  checks.cacheHitParity = {
    kiro-cli = {consumerPath = ["ai" "kiro-cli"];};
    # The patched `workflows` variant is intentionally not distributed through
    # Cachix, but parity still matters: consumers reach it through
    # `ai.kiro.unlockedRolloutFeatures`, and a consumer-pin-bound build would
    # realize a different derivation from the one the local-only CI job tests.
    kiro-cli-workflows = {consumerPath = ["ai" "kiro-cli-workflows"];};
  };
  documentation.aiCliDescriptions.kiro-cli = "Kiro CLI";
  fragments.categories = {
    # kiro-settings: how nested `native.settings` lowers into kiro's FLAT
    # cli.json, and why the flatten boundary has to come from the binary rather
    # than from attrset shape. Scoped to the flattener, the extractor that
    # measures the boundary, and the module that applies it — an edit to any of
    # those decides whether an object-valued setting reaches the file at all.
    kiro-settings = {
      scopes = [
        "lib/ai/ai-common.nix"
        "packages/${facetOwner}/lib/packaging.nix"
        "packages/${facetOwner}/lib/mkKiro.nix"
      ];
      sources = [
        {
          location = "package";
          name = "settings-shape";
          dir = facetOwner;
        }
      ];
    };
    # kiro-steering: what kiro-cli ACTUALLY does with each steering
    # `inclusion` mode, which is not what the vendor's IDE-oriented docs
    # describe — `manual` is inert in the CLI and a frontmatter fault degrades
    # to `always` silently. Scoped to the transformer that EMITS the
    # frontmatter, the option that types it, and the kiro package, because a
    # change to any of those is a change to what the engine will be handed.
    # Deliberately not scoped to all owner module tests: those also hold the
    # inclusion assertions, but it is edited constantly for unrelated reasons
    # and loading this fragment on every one of those edits is pure context
    # tax.
    kiro-steering = {
      scopes = [
        "lib/ai/ai-common.nix"
        "lib/ai/transformers/kiro.nix"
        "packages/${facetOwner}/**"
      ];
      sources = [
        {
          location = "package";
          name = "steering-inclusion";
          dir = facetOwner;
        }
      ];
    };
    # kiro-workflows: the THREE independent gates on the `workflows` feature,
    # all of which fail silently, and the extracted workspace-settings allowlist
    # that makes gate 3 global-only. Scoped to the module that implies the
    # setting and asserts the allowlist, plus the two overlay files that
    # extract and patch — a change to any of those changes what a consumer must
    # set to get a working `/workflow`.
    kiro-workflows = {
      scopes = [
        "packages/${facetOwner}/packages/ai/kiro-cli/package.nix"
        "packages/${facetOwner}/lib/packaging.nix"
        "packages/${facetOwner}/lib/mkKiro.nix"
      ];
      sources = [
        {
          location = "package";
          name = "workflow-gating";
          dir = facetOwner;
        }
      ];
    };
    # kiro-wrapper: the argv contract of the generated kiro-cli launcher /
    # chat wrappers — which subcommands accept `--tui`/`--v3`/`--trust-tools`,
    # why the appends are gated rather than unconditional, and how to
    # re-measure on a version bump. Kept OUT of the `kiro-cli` category (whose
    # fragment is the ~300-line auto-memory map) so an edit to the wrapper
    # loads the wrapper rule, not the memory pipeline. Scoped to the generic
    # shell helper, the factory's lib/ directory that consumes it, and the
    # behavioral check, since all three have to move together.
    kiro-wrapper = {
      scopes = [
        "packages/kiro-cli/checks/kiro-fhs-contract.nix"
        "packages/kiro-cli/checks/kiro-wrapper-argv.nix"
        "lib/idempotentFlags.nix"
        # The overlay's wrapProgram calls carry the darwin argv0
        # bundle-discovery fix, which is part of this argv contract.
        "packages/${facetOwner}/packages/ai/kiro-cli/package.nix"
        "packages/${facetOwner}/lib/**"
      ];
      sources = [
        {
          location = "package";
          name = "fhs-sandbox";
          dir = facetOwner;
        }
        {
          location = "package";
          name = "launcher-argv";
          dir = facetOwner;
        }
      ];
    };
  };
  update.targets.kiro-cli = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/kiro-cli/package.nix)];};
}
