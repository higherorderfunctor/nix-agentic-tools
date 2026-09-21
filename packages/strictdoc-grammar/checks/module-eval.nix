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
      in
        lib.any (n: lib.hasPrefix "strictdoc-0" n || n == "strictdoc") names
        && lib.any (lib.hasPrefix "strictdoc-grammar-extract-") names
        && builtins.elem "scribe" names
        && builtins.elem "scribe-client" names
        && builtins.elem "scribe-daemon" names
        && !(evaluated.config.processes ? board)
        && lib.hasInfix "/bin/scribe-daemon --root" evaluated.config.processes.scribe.exec
    );

    module-strictdoc-project-source-retains-board = mkTest "strictdoc-project-source-retains-board" (
      let
        evaluated = evalDevenv {
          ai.strictdoc = {
            enable = true;
            scribeSource = "project";
          };
        };
        names = map (p: p.name or "") evaluated.config.packages;
        boardExec = evaluated.config.processes.board.exec;
      in
        builtins.elem "sdoc-board" names
        && lib.hasPrefix "/nix/store/" boardExec
        && lib.hasInfix "/bin/sdoc-board --root" boardExec
    );
  };
}
