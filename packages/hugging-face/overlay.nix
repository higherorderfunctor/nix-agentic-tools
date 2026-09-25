# pkgs.ai.fetchHuggingFaceModel — an ordinary overlay leaf, not a package.
#
# It is built on the CONSUMER's `final`, so their fetchFromHuggingFace and
# their allowUnfree / allowUnfreePredicate apply. Ordinary overlay claims stay
# out of package discovery (flat flake packages, CI shards, the unfree guard,
# cache-hit parity), which only walk `packages/<owner>/packages/` claims.
#
# The leaf must stay a plain lambda. A functor attrset (what callPackage or
# makeOverridable would return) is an ordinary attrset to the claim check,
# which would then report its `__functor` / `override` as undeclared leaves.
_context: {
  claims = [["ai" "fetchHuggingFaceModel"]];
  overlay = final: prev: {
    ai =
      (prev.ai or {})
      // {
        fetchHuggingFaceModel = import ./fetch-hugging-face-model.nix {
          inherit (final) fetchFromHuggingFace lib runCommand writeText;
        };
      };
  };
}
