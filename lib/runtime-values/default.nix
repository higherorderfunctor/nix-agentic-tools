{lib}: let
  classifier = import ./classify.nix {inherit lib;};
  options = import ./options.nix {
    inherit lib types;
    inherit (classifier) classify;
  };
  isReference = value: builtins.isAttrs value && value ? _runtime;
  validReference = value:
    isReference value
    && builtins.attrNames value == ["_runtime"]
    && builtins.isAttrs value._runtime
    && builtins.attrNames value._runtime == ["secret" "source"]
    && builtins.isBool value._runtime.secret
    && builtins.isAttrs value._runtime.source
    && (
      (builtins.attrNames value._runtime.source == ["file"] && builtins.isString value._runtime.source.file)
      || (builtins.attrNames value._runtime.source == ["helper"] && builtins.isString value._runtime.source.helper)
    );
  types = import ./types.nix {
    inherit lib validReference;
    inherit (classifier) classify;
  };
  constructor = kind: {path}: {
    _runtime = {
      secret = false;
      source.${kind} = path;
    };
  };
  recognize = value:
    if validReference value
    then value._runtime
    else if !isReference value
    then null
    else throw "runtimeValues: malformed reference envelope";
in
  classifier
  // types
  // options
  // (import ./materialize.nix {
    inherit lib recognize;
    inherit (classifier) classify;
  })
  // {
    inherit isReference;
    file = constructor "file";
    helper = constructor "helper";
  }
