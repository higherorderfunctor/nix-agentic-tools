{
  lib,
  classify,
  recognize,
}: let
  reader = pkgs: import ./reader.nix {inherit pkgs;};
  assignment = {
    pkgs,
    variable,
    value,
    path ? [variable],
    secret ? false,
    argv ? false,
  }: let
    ref = recognize value;
    label = lib.showOption path;
    validVariable = builtins.match "[a-zA-Z_][a-zA-Z0-9_]*" variable != null;
    tainted = secret || classify {inherit path;} || (ref != null && ref.secret);
    kind =
      if ref.source ? file
      then "file"
      else "helper";
    command = lib.escapeShellArgs [label kind ref.source.${kind}];
    literal =
      if builtins.isBool value
      then lib.boolToString value
      else toString value;
  in
    if !validVariable
    then throw "runtimeValues: invalid variable name ${variable}"
    else if value == null
    then ""
    else if tainted && ref == null
    then throw "${label}: secret literals are forbidden"
    else if argv && tainted
    then throw "${label}: secrets cannot be delivered through argv"
    else if ref == null
    then ''${variable}=${lib.escapeShellArg literal}''
    else ''
      if ${variable}="$(${lib.getExe (reader pkgs)} ${command})"; then
        :
      else
        exit 1
      fi'';
  export = args: let
    text = assignment args;
  in
    lib.optionalString (text != "") ''
      ${text}
      export ${args.variable}'';
  environment = {
    pkgs,
    values,
    path ? [],
  }:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (variable: value:
      export {
        inherit pkgs variable value;
        path = path ++ [variable];
      })
    values);
in {
  inherit assignment environment export reader;
}
