# Claude Code — override nixpkgs' claude-code with nvfetcher-tracked version.
# Uses the same buildNpmPackage override pattern as nixos-config but with
# hashes tracked in the sidecar (not hardcoded).
{
  final,
  prev,
  nv,
}:
prev.claude-code.override (_: {
  buildNpmPackage = args:
    final.buildNpmPackage (finalAttrs: let
      a = (final.lib.toFunction args) finalAttrs;
    in
      a
      // {
        inherit (nv) version;
        src = final.fetchzip {
          url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${nv.version}.tgz";
          hash = nv.src.outputHash;
        };
        inherit (nv) npmDepsHash;
      });
})
