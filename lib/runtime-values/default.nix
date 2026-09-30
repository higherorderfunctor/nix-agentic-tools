{lib}: let
  classifier = import ./classify.nix {inherit lib;};
  types = import ./types.nix {
    inherit lib;
    inherit (classifier) classify;
  };
  options = import ./options.nix {
    inherit lib types;
    inherit (classifier) classify;
  };
  constructor = kind: {path}: {
    _runtime = {
      secret = false;
      source.${kind} = path;
    };
  };
  recognize = value: value._runtime or null;
in
  classifier
  // types
  // options
  // (import ./materialize.nix {
    inherit lib recognize;
  })
  // {
    inherit recognize;
    file = constructor "file";
    helper = constructor "helper";
  }
