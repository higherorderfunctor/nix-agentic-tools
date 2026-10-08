{lib}: let
  inherit (import ../runtime-values/classify.nix {inherit lib;}) classify;
  isReference = value: builtins.isAttrs value && value ? _redact;
  validReference = value:
    isReference value
    && builtins.attrNames value == ["_redact"]
    && builtins.isAttrs value._redact
    && (builtins.attrNames value._redact == ["command"] || builtins.attrNames value._redact == ["file"])
    && lib.all (path: builtins.isString path && lib.hasPrefix "/" path) (builtins.attrValues value._redact)
    # Interpolated Nix paths have already copied the file into the store.
    && (!(value._redact ? file) || !builtins.hasContext value._redact.file);
  reference = lib.types.mkOptionType {
    name = "redacted reference";
    description = "a redact.file or redact.command reference";
    # Reject in merge so the module error never prints an attempted literal secret.
    check = _: true;
    merge = loc: defs:
      if lib.all (def: validReference def.value) defs
      then lib.options.mergeEqualOption loc defs
      else throw "${lib.showOption loc}: expected a redact reference; literal secrets are forbidden";
  };
  maybeRedacted = type:
    if type.name != "str"
    then throw "redact.types.maybeRedacted supports str only"
    else
      lib.types.mkOptionType {
        name = "string or redacted reference";
        description = "a string or redact reference";
        check = _: true;
        merge = loc: defs:
          if lib.all (def: type.check def.value) defs
          then type.merge loc defs
          else if lib.all (def: validReference def.value) defs
          then reference.merge loc defs
          else throw "${lib.showOption loc}: expected a string or redact reference";
      };
  environmentEntry = lib.types.mkOptionType {
    name = "environment value";
    description = "a string or redact reference; secret-named entries require a reference";
    check = _: true;
    merge = loc: defs:
      if builtins.match "[a-zA-Z_][a-zA-Z0-9_]*" (lib.last loc) == null
      then throw "${lib.showOption loc}: invalid environment variable name"
      else
        (
          if classify {path = loc;}
          then reference
          else maybeRedacted lib.types.str
        ).merge
        loc
        defs;
  };
  environmentType = lib.types.attrsOf (lib.types.nullOr environmentEntry);
  reader = pkgs: import ./reader.nix {inherit pkgs;};
  read = {
    pkgs,
    value,
    option,
    target,
    export ? false,
  }: let
    source = value._redact;
    kind = builtins.head (builtins.attrNames source);
    args = lib.escapeShellArgs [option kind source.${kind}];
    assignment =
      if isReference value
      then
        if !validReference value
        then throw "${option}: malformed redact reference"
        else ''
          if ${target}="$(${lib.getExe (reader pkgs)} ${args})"; then
            :
          else
            exit 1
          fi''
      else if builtins.isString value
      then ''${target}=${lib.escapeShellArg value}''
      else throw "${option}: expected a string or redact reference";
  in
    if builtins.match "[a-zA-Z_][a-zA-Z0-9_]*" target == null
    then throw "${option}: invalid shell variable name"
    else if value == null
    then ""
    else assignment + lib.optionalString export "\nexport ${target}";
in {
  inherit isReference read reader;
  command = {path}: {_redact.command = path;};
  environment = {
    pkgs,
    values,
    option,
  }: let
    checked = environmentType.merge [option] [
      {
        file = "redact.environment";
        value = values;
      }
    ];
  in
    lib.concatStringsSep "\n" (lib.mapAttrsToList (target: value:
      read {
        inherit pkgs target value;
        export = true;
        option = "${option}.${target}";
      })
    checked);
  file = {path}: {_redact.file = path;};
  filePath = value:
    if isReference value && value._redact ? file
    then value._redact.file
    else null;
  types = {
    environment = environmentType;
    inherit environmentEntry maybeRedacted;
    redacted = reference;
  };
}
