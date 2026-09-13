let
  source = /nix/store/121pk8i5nzhrpm34fv97f7mywin6k1r0-strictdoc-toolchain-source;
  lock = builtins.fromJSON (builtins.readFile (source + "/flake.lock"));
  # Evaluate exactly the supplied lock without copying the filtered root.
  resolve = edge:
    if builtins.isList edge
    then builtins.foldl' (node: name: node.inputs.${name}) nodes.root edge
    else nodes.${edge};
  nodes = builtins.mapAttrs (name: node: let
    src =
      if name == "root"
      then source
      else (builtins.fetchTree node.locked).outPath;
    inputs = builtins.mapAttrs (_: resolve) (node.inputs or {});
    result = (import (src + "/flake.nix")).outputs (inputs // {self = result;});
  in
    result
    // {
      inherit inputs;
      outPath = src;
    })
  lock.nodes;
  pkgs = import nodes.nixpkgs_4.outPath {
    system = "x86_64-linux";
    config = {};
    overlays = [];
  };
  strictdoc = nodes.root.packages.x86_64-linux.strictdoc;
  python = pkgs.python314;
  rustworkx = pkgs.python314Packages.rustworkx;
in {
  inherit strictdoc python rustworkx;
  identities = {
    strictdocSource = nodes.strictdoc.outPath;
    nixpkgsSource = nodes.nixpkgs_4.outPath;
    strictdoc = strictdoc.outPath;
    strictdocDrv = strictdoc.drvPath;
    python = python.outPath;
    pythonVersion = python.version;
    rustworkx = rustworkx.outPath;
    rustworkxVersion = rustworkx.version;
    rustworkxDrv = rustworkx.drvPath;
  };
  closure = pkgs.symlinkJoin {
    name = "gate2-runtime-probe-closure";
    paths = [strictdoc (python.withPackages (_: [rustworkx]))];
  };
}
