# Fixture gate for the settings-census memoizer anchor.
#
# `claude-code-extracted` proves the committed sidecar matches the PINNED
# binary, which says nothing about whether locate.mjs will still find the
# lazy-thunk memoizer in the NEXT one. That anchor has held the update sweep
# back twice (2.1.248, 2.1.283) with a shape change the pinned binary never
# shows, so it gets a check that runs the locator over every memoizer shape
# that has shipped plus decoys — synthetic modules of a few hundred bytes, not
# an unpacked binary. They carry a `.js.txt` extension so no formatter
# restyles the minified shape under test. Eval is cheap and the build needs
# only node.
{pkgs, ...}: {
  checks.claude-extract-locate =
    pkgs.runCommandLocal "claude-extract-locate-check" {
      # nodejs_24 to match the extraction build in package.nix.
      nativeBuildInputs = [pkgs.nodejs_24];
    } ''
      node ${./claude-extract-locate.mjs} ${../extract} ${./fixtures/claude-extract}
      touch "$out"
    '';
}
