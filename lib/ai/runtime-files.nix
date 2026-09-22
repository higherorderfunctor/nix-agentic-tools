# Validation and native lowering for `ai.<runtime>.files`.
#
# The option's TYPE lives in `lib/ai/delivery-options.nix` beside the writer
# submodule, because the two describe one layer. What is left here is the
# `apply` that rejects a malformed map before anything reads it, and the
# lowering of a symlinked entry into the shape both backends' file sinks take.
{lib}: let
  aiTypes = import ./types.nix {inherit lib;};
  targetIsNormalized = target: let
    segments = lib.splitString "/" target;
  in
    target
    != ""
    && !(lib.hasPrefix "/" target)
    && lib.all (segment: segment != "" && segment != "." && segment != "..") segments;
in rec {
  # One live entry as the native sink wants it. `executable` is stated unless
  # it is null, because both backends default it themselves and a silent
  # divergence between the two is what this seam exists to prevent — while a
  # null means "leave the source's mode alone" and has to reach the sink as an
  # ABSENT attribute, which is how a tree of source files keeps its modes.
  # `recursive` is stated only when true: Home Manager reads its absence as
  # false and the devenv adapter has no such option at all.
  sinkEntry = entry:
    lib.optionalAttrs (entry.executable != null) {inherit (entry) executable;}
    // lib.optionalAttrs entry.recursive {recursive = true;}
    // aiTypes.textSourceFile entry.content;
  validateFiles = runtime: files: let
    invalidTargets = builtins.filter (target: !targetIsNormalized target) (builtins.attrNames files);
    contentKinds = entry:
      lib.optional entry.content.enable "text or source"
      ++ lib.optional (entry.content.run != null) "run"
      ++ lib.optional (entry.content.value != null) "value";
    malformed = lib.filterAttrs (_target: entry: let
      count = builtins.length (contentKinds entry);
    in
      count
      > 1
      || (count == 0 && !entry.content._enableExplicit && !entry.content._textSourceDefined))
    files;
  in
    if invalidTargets != []
    then
      throw ''
        ai.${runtime}.files targets must be non-empty normalized relative paths
        without absolute roots, empty segments, or `.`/`..` traversal segments;
        invalid target(s): ${lib.concatStringsSep ", " invalidTargets}
      ''
    else if malformed == {}
    then files
    else
      throw ''
        ai.${runtime}.files entries must enable exactly one content form:
        `text`/`source`, `run`, or `value`; invalid entries:
        ${lib.concatStringsSep ", " (builtins.attrNames malformed)}
      '';

  # The shared repository AGENTS.md map lowers through here rather than
  # through the router: it is one arbitrated target rather than a runtime's
  # delivery description, and it has no methods, facts or writers.
  liveFiles = files:
    lib.mapAttrs (_target: sinkEntry)
    (lib.filterAttrs (_target: entry:
      entry.content.enable || entry.content.run != null || entry.content.value != null)
    files);
}
