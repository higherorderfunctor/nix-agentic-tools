# A clean consumer flake: public grammar/module code and installed scribe only.
# Runtime membership stays owned by scribeSource; upstream pins stay owned by
# the repository lock. No domain model or document tree enters this source.
{
  lib,
  pkgs,
}: let
  # Package-relative paths keep source owner relocation independent from the
  # canonical paths in the exported consumer flake.
  source = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ./check.nix
      ./default.nix
      ./denormalize.nix
      ./dsl.nix
      ./emit.nix
      ./faithful.nix
      ./grammar.nix
      ./mkExtract.nix
      ./mkScribe.nix
      ./normalized.nix
      ./pjrpc.nix
      ./scribeSource.nix
      ./sgra.nix
      ./tsGrammars.nix
      ../modules/devenv/default.nix
    ];
  };
  runtime = import ./scribeSource.nix {inherit lib;};
  parentLock = builtins.fromJSON (builtins.readFile ../../../flake.lock);
  dependencyKey = value:
    if builtins.isString value
    then value
    else if builtins.isList value && value != [] && builtins.head value == "strictdoc"
    then
      lib.foldl' (node: name: dependencyKey parentLock.nodes.${node}.inputs.${name})
      "strictdoc" (builtins.tail value)
    else throw "strictdoc-toolchain-source: upstream follows must stay rooted in strictdoc";
  dependencies = builtins.genericClosure {
    startSet = [{key = "strictdoc";}];
    operator = item:
      map (value: {key = dependencyKey value;})
      (builtins.attrValues (parentLock.nodes.${item.key}.inputs or {}));
  };
  upstream = parentLock.nodes.strictdoc.locked;
  lock = {
    nodes =
      builtins.listToAttrs (map (item: {
          name = item.key;
          value = parentLock.nodes.${item.key};
        })
        dependencies)
      // {
        root.inputs.strictdoc = "strictdoc";
        strictdoc = parentLock.nodes.strictdoc // {original = builtins.removeAttrs upstream ["lastModified" "narHash"];};
      };
    root = "root";
    inherit (parentLock) version;
  };
  entrypoint = pkgs.writeText "strictdoc-toolchain-flake.nix" ''
    {
      inputs.strictdoc.url = "github:${upstream.owner}/${upstream.repo}/${upstream.rev}";
      outputs = {strictdoc, ...}: {
        devenvModules.nix-agentic-tools = import ./packages/strictdoc-grammar/modules/devenv;
        lib = import ./packages/strictdoc-grammar/lib;
        packages = builtins.mapAttrs (_: packages: {strictdoc = packages.default;}) strictdoc.packages;
      };
    }
  '';
in
  pkgs.runCommand "strictdoc-toolchain-source" {} ''
    mkdir -p "$out/dev/scripts" "$out/packages/strictdoc-grammar" # bare-commands: ok
    cp -r ${source}/. "$out/packages/strictdoc-grammar/" # bare-commands: ok
    cp -r ${runtime}/. "$out/dev/scripts/" # bare-commands: ok
    cp ${entrypoint} "$out/flake.nix" # bare-commands: ok
    cp ${pkgs.writeText "strictdoc-toolchain-flake.lock" (builtins.toJSON lock)} "$out/flake.lock" # bare-commands: ok
  ''
