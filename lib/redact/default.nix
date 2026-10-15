# Secrets kept out of the Nix store. A reference names where a value lives;
# nothing is read at evaluation, and the reader resolves it when a launcher
# starts. Design and the leak-safe error choice: dev/fragments/redact/redact.md.
{lib}: let
  inherit (import ../runtime-values {inherit lib;}) classify;

  # An interpolated Nix path has already copied the file into the store, so a
  # path string carrying store context names a world-readable copy. A path is
  # also refused with an empty, `.` or `..` segment, so the store test below
  # sees the path the reader will open; symlinks are not resolved.
  isPath = path:
    builtins.isString path
    && lib.hasPrefix "/" path
    && !builtins.hasContext path
    && !lib.any (lib.flip lib.elem ["" "." ".."]) (lib.tail (lib.splitString "/" path));
  # A file in the store is world-readable whatever its context. A command skips
  # this location test, because its program is code and its output is the
  # value; `isPath` still refuses context for both kinds alike.
  inStore = path: lib.hasPrefix "${builtins.storeDir}/" path;
  isMarker = value: builtins.isAttrs value && builtins.attrNames value == ["_redact"] && builtins.isAttrs value._redact;
  isReference = value:
    isMarker value
    && lib.elem (builtins.attrNames value._redact) [["command"] ["file"]]
    && isPath (value._redact.command or value._redact.file)
    && !(value._redact ? file && inStore value._redact.file);
  isConcat = value:
    isMarker value
    && builtins.attrNames value._redact == ["concat"]
    && builtins.isList value._redact.concat
    && lib.all (part: builtins.isString part || isReference part) value._redact.concat;
  isRedacted = value: isReference value || (isConcat value && lib.any isReference value._redact.concat);
  isName = name: builtins.match "[A-Za-z_][A-Za-z0-9_]*" name != null;

  # The one refusal. It names where the value was refused and never the value:
  # a refused value is most often a secret typed where a reference belongs.
  sealed = where: value:
    if isRedacted value
    then value
    else
      throw ''
        ${where}: refused a value that is not a redact reference. It is not printed, since it may be a secret.
        Use redact.file with an absolute path outside the Nix store, redact.command with an absolute program path, or redact.concat with at least one of them.
        A path has no string context and no empty, `.` or `..` segment.'';

  # `check` accepts everything because the module system prints a definition
  # that fails `check`; `merge` refuses through `sealed` instead.
  redacted = lib.types.mkOptionType {
    name = "redacted";
    description = "redact reference (redact.file, redact.command, or redact.concat holding one)";
    check = _: true;
    merge = loc: defs:
      lib.options.mergeEqualOption loc
      (map (def: def // {value = sealed (lib.showOption loc) def.value;}) defs);
  };

  # A marker always goes to `redacted`, so a type whose check accepts any
  # attribute set (attrsOf, submodule) never takes a reference as cleartext.
  maybeRedacted = type:
    lib.types.mkOptionType {
      name = "maybeRedacted";
      description = "${type.description} or ${redacted.description}";
      check = _: true;
      merge = loc: defs:
        if lib.all (def: !(def.value ? _redact) && type.check def.value) defs
        then type.merge loc defs
        else redacted.merge loc defs;
    };

  # The name is checked before null is taken, so `{"BAD-NAME" = null;}` is
  # refused too. A null beside a value is a conflict, refused here rather than
  # by `sealed`, which would blame the redact API.
  environmentValue = lib.types.mkOptionType {
    name = "environmentValue";
    description = "null, string or ${redacted.description}; a secret-named variable takes only the reference";
    check = _: true;
    merge = loc: defs:
      if !(isName (lib.last loc))
      then throw "${lib.showOption loc}: the variable name is not a shell identifier"
      else if lib.all (def: def.value == null) defs
      then null
      else if lib.any (def: def.value == null) defs
      then throw "${lib.showOption loc}: defined both null and not null"
      else
        (
          if classify {path = loc;}
          then redacted
          else maybeRedacted lib.types.str
        ).merge
        loc
        defs;
  };
in {
  # Launch-time shell assigning `value` to the consumer's `variable`, then
  # exporting it when asked. Literals are shell-escaped; a reference or concat
  # goes through the reader, whose argv holds the label, kinds, paths and
  # literal parts only. `|| exit 1` aborts even where the caller has no errexit.
  assign = {
    pkgs,
    option,
    variable,
    value,
    export ? false,
  }: let
    reader = lib.getExe (import ./reader.nix {inherit pkgs;});
    checked = sealed option value;
    parts =
      if isConcat checked
      then checked._redact.concat
      else [checked];
    words = part:
      if builtins.isString part
      then ["literal" part]
      else let
        kind = lib.head (builtins.attrNames part._redact);
      in [kind part._redact.${kind}];
    assignment =
      if builtins.isString value
      then "${variable}=${lib.escapeShellArg value}"
      else ''${variable}="$(${reader} ${lib.escapeShellArgs ([option] ++ lib.concatMap words parts)})" || exit 1'';
  in
    if !(isName variable)
    then throw "${option}: the variable name is not a shell identifier"
    else if value == null
    then ""
    else assignment + lib.optionalString export "\nexport ${variable}";
  command = path: sealed "redact.command" {_redact.command = path;};
  concat = parts: sealed "redact.concat" {_redact.concat = parts;};
  file = path: sealed "redact.file" {_redact.file = path;};
  types = {
    # Secret-classified names (lib/runtime-values) take `redacted`, any other
    # name `maybeRedacted str`. null drops the definition and `assign` emits
    # nothing for it: an inherited variable is not unset, which is left to the
    # consumer's launcher.
    environment = lib.types.attrsOf environmentValue;
    inherit maybeRedacted redacted;
  };
}
