# These are the repository's module sets with the shared harness's backend stubs,
# not a user's complete Home Manager/devenv configuration.
{
  root,
  source,
}: let
  flake = builtins.getFlake "path:${toString root}";
  inherit (flake) inputs;
  inherit (inputs.nixpkgs) lib;
  repository = import (root + "/lib/facets/repository.nix") {inherit inputs root;};
  pkgs = repository.natSets.${builtins.currentSystem};
  harness = import (root + "/lib/testing/module-harness.nix") {
    inherit inputs lib pkgs;
    inherit (repository) moduleImports moduleInternals;
    testing.homeManagerAiPackages = {};
  };
  result =
    if source == "devenv"
    then harness.evalDevenvModules [(import (root + "/dev/ai.nix") {isCI = false;})]
    else if source == "home-manager"
    then harness.evalHmModules []
    else if source == "facets"
    then
      (repository.checkWorldFor {
        self = flake;
        inherit pkgs;
        updateRegistry = repository.update;
        rootModules = (import (root + "/lib/testing/discover.nix") {inherit lib;}) (root + "/checks");
      }).evaluated
    else throw "unknown CodeQL eval source ${source}";
in {
  inherit lib result;
  modules = result.type.getSubModules;
}
