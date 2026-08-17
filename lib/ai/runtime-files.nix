# Shared literal-file option and backend lowering.
#
# This is the final static output seam for every `ai.<runtime>.files` map:
# generators contribute whole entries at `mkDefault` priority, consumers may
# replace or tombstone them, and the surviving entries lower one-way into the
# active backend's native file sink. Nothing in this layer feeds back into a
# normalized input pool.
{lib}: let
  hasExactlyOneContent = entry:
    ((entry.text or null) == null) != ((entry.source or null) == null);
  entrySubmodule =
    lib.types.addCheck (lib.types.submodule {
      options = {
        executable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether the materialized file should be executable.";
        };
        source = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Store-backed source for the file. Mutually exclusive with text.";
        };
        text = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Literal file content. Mutually exclusive with source.";
        };
      };
    })
    hasExactlyOneContent;

  nullableEntry = lib.types.nullOr entrySubmodule;

  # An attrsOf-submodule normally merges fields independently. A final output
  # registry needs the opposite contract: priority selects one WHOLE entry.
  # Normalize each surviving same-priority definition through the submodule,
  # deduplicate byte-identical values, and reject divergent values.
  mkAtomicEntry = nullableType:
    lib.types.mkOptionType rec {
      name = "atomicLiteralFile";
      inherit (nullableType) description descriptionClass;
      check = value:
        value
        == null
        || (entrySubmodule.check value && hasExactlyOneContent value);
      merge = loc: defs: let
        normalize = definition:
          if check definition.value
          then nullableType.merge loc [definition]
          else throw "The option `${lib.showOption loc}` must set exactly one of `text` or `source`";
        values = lib.unique (map normalize defs);
      in
        if builtins.length values == 1
        then builtins.head values
        else throw "The option `${lib.showOption loc}` has divergent whole-file definitions at the same priority";
      inherit (nullableType) emptyValue getSubModules getSubOptions;
      substSubModules = modules: mkAtomicEntry (nullableType.substSubModules modules);
      nestedTypes.elemType = nullableType;
    };
  atomicEntry = mkAtomicEntry nullableEntry;

  targetIsNormalized = target: let
    segments = lib.splitString "/" target;
  in
    target
    != ""
    && !(lib.hasPrefix "/" target)
    && lib.all (segment: segment != "" && segment != "." && segment != "..") segments;
in rec {
  fileEntryType = atomicEntry;
  fileMapType = lib.types.attrsOf fileEntryType;

  validateFiles = runtime: files: let
    invalidTargets = builtins.filter (target: !targetIsNormalized target) (builtins.attrNames files);
    invalidEntries = builtins.attrNames (lib.filterAttrs (
        _target: entry: entry != null && !hasExactlyOneContent entry
      )
      files);
  in
    if invalidTargets != []
    then
      throw ''
        ai.${runtime}.files targets must be non-empty normalized relative paths
        without absolute roots, empty segments, or `.`/`..` traversal segments;
        invalid target(s): ${lib.concatStringsSep ", " invalidTargets}
      ''
    else if invalidEntries == []
    then files
    else
      throw ''
        ai.${runtime}.files entries must set exactly one of `text` or `source`;
        invalid target(s): ${lib.concatStringsSep ", " invalidEntries}
      '';

  liveFiles = files:
    lib.mapAttrs (_target: lib.filterAttrs (_field: value: value != null))
    (lib.filterAttrs (_target: entry: entry != null) files);

  mkBackendSink = {
    backend,
    files,
  }:
    if backend == "hm"
    then {home.file = liveFiles files;}
    else if backend == "devenv"
    then {files = liveFiles files;}
    else throw "runtime-files: unsupported backend `${backend}`";
}
