# The shared harness discovers the owner backend through native composition.
{
  lib,
  harness,
  ...
}: let
  inherit (harness) evalDevenv mkTest;
  strictdocDevenvNames = config:
    map (p: p.name or "") (evalDevenv config).config.packages;
in {
  checks = {
    module-strictdoc-inert-when-disabled = mkTest "strictdoc-inert-when-disabled" (!(lib.any (n: lib.hasPrefix "strictdoc" n) (strictdocDevenvNames {})));

    module-strictdoc-enable-installs-cli-and-runner = mkTest "strictdoc-enable-installs-cli-and-runner" (
      let
        evaluated = evalDevenv {ai.strictdoc.enable = true;};
        names = map (p: p.name or "") evaluated.config.packages;
        boardExec = evaluated.config.processes.board.exec;
      in
        lib.any (n: lib.hasPrefix "strictdoc-0" n || n == "strictdoc") names
        && lib.any (lib.hasPrefix "strictdoc-grammar-extract-") names
        && lib.any (n: lib.hasPrefix "sdoc-board-" n || n == "sdoc-board") names
        && lib.hasPrefix "/nix/store/" boardExec
        && lib.hasInfix "/bin/sdoc-board --root" boardExec
    );
  };
}
