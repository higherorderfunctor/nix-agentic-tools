# A runtime's generated files: its staged entries (`ai.<runtime>._generatedFiles`,
# `S`), the one formatted, guarded and checked store tree their bytes enter,
# and the layer-1 definitions (`ai.<runtime>.files2`, `R`) they become.
{
  lib,
  pkgs,
}: let
  files2 = import ../../../packages/ai-module/lib/files/default.nix {inherit lib pkgs;};
  generated = import ../../generated.nix {inherit lib;} pkgs;
  surfaces = ["agents" "context" "hooks" "mcpServers" "rules" "settings" "skills"];
  renderers = {
    json = _name: value: {text = builtins.toJSON value;};
    toml = name: value: {source = (pkgs.formats.toml {}).generate name value;};
    yaml = name: value: {source = (pkgs.formats.yaml {}).generate name value;};
  };
  live = lib.filterAttrs (_path: entry: entry.enable);
  # A staged entry in a format that cannot carry `value` is one whole-content
  # default at layer 1, so a stronger content definition (a consumer's
  # replacement) discards it before it is evaluated, as compiled context needs.
  whole = entry: builtins.elem entry.format ["markdown" "raw"];
  replacedWhole = files2: path: entry: whole entry && files2.${path}._contentPrio < (lib.mkDefault null).priority;
  # The content `S` contributes to `R` per live path. Text and non-recursive
  # source become their formatted file in `tree`. A recursive source and `run`
  # pass as themselves: the engine walks a recursive source at evaluation,
  # where walking a tree output would be import-from-derivation, and `run` has
  # no build-time bytes. A value stays a value; it enters the tree only for
  # guards, checks and limits.
  content = {
    staged,
    tree,
  }:
    lib.mapAttrs (path: entry: let
      choice = entry.content._choice;
    in
      if choice == null
      then {}
      else if builtins.elem choice ["source" "text"] && !entry.recursive
      then {source = "${tree}/${path}";}
      else {${choice} = entry.content.${choice};})
    (live staged);
in {
  inherit content surfaces;

  generatedTreeOption = lib.mkOption {
    type = lib.types.nullOr lib.types.raw;
    readOnly = true;
    internal = true;
    visible = false;
    description = "The generated-tree derivation this runtime delivers, exposed for module checks.";
  };

  maxBytesOption = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        bytes = lib.mkOption {
          type = lib.types.ints.positive;
          description = "The largest size, in bytes, the reader takes whole.";
        };
        hint = lib.mkOption {
          type = lib.types.str;
          description = "What to do about a file past the limit; ends the build failure message.";
        };
      };
    });
    default = {};
    internal = true;
    visible = false;
    description = "Byte limits on generated files, keyed by path, checked on the built file.";
  };

  # Whether a staged path's final content (`files2.<path>`) is not the
  # generated one. A whole-content default is judged by priority alone, so the
  # discarded content stays unevaluated; a value document merges per leaf and
  # is replaced only by another alternative.
  replaced = {
    files2,
    generated,
    staged,
  }: path: let
    entry = files2.${path};
    choice = entry.content._choice;
  in
    if whole staged.${path}
    then replacedWhole files2 path staged.${path}
    else choice != null && (!(generated.${path} ? ${choice}) || (choice != "value" && entry.content.${choice} != generated.${path}.${choice}));

  # `S` → `R`, every field at `mkDefault` so a consumer's `R` definition wins.
  # A value gets one default per leaf, so a consumer leaf merges with its
  # generated siblings instead of replacing the document.
  layer1 = args: let
    generatedContent = content args;
  in
    lib.mapAttrs (path: entry: {
      content =
        if whole entry
        then lib.mkDefault generatedContent.${path}
        else
          lib.mapAttrs (choice: value:
            if choice == "value"
            then lib.mapAttrsRecursive (_leaf: lib.mkDefault) value
            else lib.mkDefault value)
          generatedContent.${path};
      executable = lib.mkDefault entry.executable;
      format = lib.mkDefault entry.format;
      method = lib.mkDefault entry.method;
      mode = lib.mkDefault entry.mode;
      recursive = lib.mkDefault entry.recursive;
      # Delivery waits for the tree, so its checks gate a recursive source or a
      # value that does not point into it.
      requires = lib.mkDefault (lib.optional (args.tree != null) args.tree);
    })
    (live args.staged);

  # `S`: the files engine entry plus the surface whose checks its bytes run.
  stagedOption = lib.mkOption {
    type = lib.types.attrsOf (files2.entryType.substSubModules (files2.entryType.getSubModules
      ++ [
        {
          options.surface = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum surfaces);
            default = null;
          };
        }
      ]));
    default = {};
    internal = true;
    visible = false;
  };

  # `entries` maps a path to `{ content = {text} | {source} | {value};
  # format; recursive; surface; }`. Every build-time whole file enters one
  # tree, which runs `ai.guards`, the runtime's `checks.<surface>` and its
  # byte limits.
  tree = {
    backend,
    checks,
    config,
    entries,
    maxBytes,
    runtime,
  }:
    if entries == {}
    then null
    else
      generated.mkTree {
        name = "ai-${backend}-${runtime}-generated";
        files = lib.mapAttrs (path: entry:
          (
            if entry.content ? value
            then renderers.${entry.format} ("ai-generated-" + lib.replaceStrings ["/"] ["-"] path) entry.content.value
            else entry.content
          )
          // {
            inherit (entry) surface;
            type =
              if entry.recursive
              then "raw"
              else entry.format;
          })
        entries;
        maxBytes = lib.filterAttrs (path: _limit: entries ? ${path}) maxBytes;
        inherit checks runtime;
        inherit (config.ai) guards;
        treefmt = config.ai.internal.formatter;
      };

  # The live staged entries with build-time bytes, as `tree` entries. One
  # whose `files2` entry is switched off, or whose whole content `files2`
  # replaced, is left out unevaluated.
  treeEntries = {
    files2,
    staged,
  }:
    lib.mapAttrs (_path: entry: {
      content.${entry.content._choice} = entry.content.${entry.content._choice};
      inherit (entry) format recursive surface;
    })
    (lib.filterAttrs (path: entry: !(files2 ? ${path} && (!files2.${path}.enable || replacedWhole files2 path entry)) && builtins.elem entry.content._choice ["source" "text" "value"]) (live staged));
}
