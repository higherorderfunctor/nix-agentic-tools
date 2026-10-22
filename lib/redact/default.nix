# Secrets kept out of the Nix store. A reference names where a value lives;
# nothing is read at evaluation, and the reader resolves it when a launcher
# starts. Design and the leak-safe error choice: dev/fragments/redact/redact.md.
{lib}: let
  inherit (import ./classify.nix {inherit lib;}) classify;

  # A path is refused with an empty, `.` or `..` segment, so the path tested is
  # the path the reader opens or runs; symlinks are not resolved.
  isPath = path:
    builtins.isString path
    && lib.hasPrefix "/" path
    && !lib.any (lib.flip lib.elem ["" "." ".."]) (lib.tail (lib.splitString "/" path));
  # A file in the store is world-readable: an interpolated Nix path
  # (`"${./secret}"`) carries context naming that copy, and a context-free
  # `toString ./secret` from a flake still points into the store. A command takes neither
  # test, because its program is code and its output is the value; its
  # context makes the program a dependency of the launcher that runs it.
  isSecretFile = path: isPath path && !builtins.hasContext path && !lib.hasPrefix "${builtins.storeDir}/" path;
  # `_redact` is reserved syntax: an attribute set that has the key claims to
  # be a reference, valid or not, whatever else it holds. A marker is the
  # reserved set with that key alone.
  isReserved = value: builtins.isAttrs value && value ? _redact;
  isMarker = value: isReserved value && builtins.attrNames value == ["_redact"] && builtins.isAttrs value._redact;
  isReference = value:
    isMarker value
    && lib.elem (builtins.attrNames value._redact) [["command"] ["file"]]
    && (
      if value._redact ? file
      then isSecretFile value._redact.file
      else isPath value._redact.command
    );
  isConcat = value:
    isMarker value
    && builtins.attrNames value._redact == ["concat"]
    && builtins.isList value._redact.concat
    && lib.all (part: builtins.isString part || isReference part) value._redact.concat;
  isRedacted = value: isReference value || (isConcat value && lib.any isReference value._redact.concat);
  # A reference whose option chose path delivery: `types.secretFile` tags it,
  # and only the ai.services launcher delivers it, as a file it writes.
  isAsFile = value: isMarker value && builtins.attrNames value._redact == ["asFile"] && isRedacted value._redact.asFile;
  isName = name: builtins.match "[A-Za-z_][A-Za-z0-9_]*" name != null;

  # The one refusal. It names where the value was refused and never the value:
  # a refused value is most often a secret typed where a reference belongs.
  sealed = where: value:
    if isRedacted value
    then value
    else if isAsFile value
    then throw "${where}: takes the secret value, and this is a redact.types.secretFile, delivered only by an ai.services launcher as the path of a file it writes at start. Give this option the reference itself."
    else
      throw ''
        ${where}: refused a value that is not a redact reference. It is not printed, since it may be a secret.
        Use redact.file with an absolute path outside the Nix store, redact.command with an absolute program path, or redact.concat with at least one of them.
        A path has no empty, `.` or `..` segment, and a file path has no string context.'';

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

  # The option definer picks path delivery by picking this type: it takes what
  # `redacted` takes and tags it, so consumers write the ordinary constructors.
  # A tagged definition passes as is, so a secretFile value can be forwarded.
  # `seq` refuses a plaintext definition at merge, not when a launcher reads it.
  tagged = where: value: let
    checked = sealed where value;
  in
    if isAsFile value
    then value
    else builtins.seq checked {_redact.asFile = checked;};
  secretFile = lib.types.mkOptionType {
    name = "secretFile";
    description = "${redacted.description}, delivered by ai.services as the path of a 0600 file holding its value";
    check = _: true;
    merge = loc: defs:
      lib.options.mergeEqualOption loc
      (map (def: def // {value = tagged (lib.showOption loc) def.value;}) defs);
  };

  # Where ai.services delivers a value: `type`, or a value a secretFile option
  # tagged. Mixing the two is refused rather than tagging the other.
  orSecretFile = type:
    lib.types.mkOptionType {
      name = "orSecretFile";
      description = "${type.description} or ${secretFile.description}";
      check = _: true;
      merge = loc: defs:
        if lib.all (def: !isAsFile def.value) defs
        then type.merge loc defs
        else if lib.all (def: isAsFile def.value) defs
        then secretFile.merge loc defs
        else throw "${lib.showOption loc}: defined both as a redact.types.secretFile value and as another value";
    };

  # A marker always goes to `redacted`, so a type whose check accepts any
  # attribute set (attrsOf, submodule) never takes a reference as cleartext.
  maybeRedacted = type:
    lib.types.mkOptionType {
      name = "maybeRedacted";
      description = "${type.description} or ${redacted.description}";
      check = _: true;
      merge = loc: defs:
        if lib.all (def: !isReserved def.value && type.check def.value) defs
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
        (orSecretFile (
          if classify {path = loc;}
          then redacted
          else maybeRedacted lib.types.str
        )).merge
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
  # The one copy of the marker tests and the refusal, for consumers that walk
  # values (the extracted render) or test paths as the reader opens them.
  inherit isAsFile isPath isRedacted isReserved sealed;
  # Every `redact.file` path a value reads: the reference itself, or the file
  # parts of a concat, through a secretFile tag. A literal or null reads none.
  filePaths = value: let
    reference =
      if isAsFile value
      then value._redact.asFile
      else value;
    parts =
      if reference == null || builtins.isString reference
      then []
      else reference._redact.concat or [reference];
  in
    lib.concatMap (part: lib.optional (builtins.isAttrs part && part._redact ? file) part._redact.file) parts;
  types = {
    # Secret-classified names (classify.nix) take `redacted`, any other
    # name `maybeRedacted str`. null drops the definition and `assign` emits
    # nothing for it: an inherited variable is not unset, which is left to the
    # consumer's launcher.
    # A secretFile value is accepted too, for ai.services; `assign` refuses it.
    environment = lib.types.attrsOf environmentValue;
    inherit maybeRedacted orSecretFile redacted secretFile;
  };
}
