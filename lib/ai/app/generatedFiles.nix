# A runtime's generated files: its staged entries (`ai.<runtime>._generatedFiles`,
# `S`), the one formatted, guarded and checked store tree their bytes enter,
# and the layer-1 definitions (`ai.<runtime>.files2`, `R`) they become. While
# the old path coexists, its router (`deliver.nix`) builds that tree with its
# own entries added, so a runtime still has exactly one.
{
  lib,
  pkgs,
}: let
  files2 = import ../../../packages/ai-module/lib/files/default.nix {inherit lib pkgs;};
  formats = import ../formats.nix {inherit lib pkgs;};
  generated = import ../../generated.nix {inherit lib;} pkgs;
  inherit (import ../delivery-options.nix {inherit lib;}) surfaces;
  live = lib.filterAttrs (_path: entry: entry.enable);
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
  inherit content;

  # Transitional, until the old path is deleted: a destination is live on one
  # delivery path, never on both, so `own.py` and the engine never own it
  # together. A live staged path counts even when its `R` entry is switched
  # off: the old path's file would still carry the staged bytes from the tree.
  disjoint = {
    files2,
    old,
    option,
    staged,
  }: let
    liveStaged = live staged;
    both = builtins.filter (path: lib.attrByPath [path "enable"] false files2 || liveStaged ? ${path}) (builtins.attrNames old);
  in {
    assertion = both == [];
    message = "${option} and ai.files2 (directly or through the runtime's generated files) both deliver ${lib.concatStringsSep ", " both}; keep one.";
  };

  # `S` → `R`, every field at `mkDefault` so a consumer's `R` definition wins.
  # A value gets one default per leaf, so a consumer leaf merges with its
  # generated siblings instead of replacing the document.
  layer1 = args: let
    generatedContent = content args;
  in
    lib.mapAttrs (path: entry: {
      content = lib.mapAttrs (choice: value:
        if choice == "value"
        then lib.mapAttrsRecursive (_leaf: lib.mkDefault) value
        else lib.mkDefault value)
      generatedContent.${path};
      executable = lib.mkDefault entry.executable;
      format = lib.mkDefault entry.format;
      method = lib.mkDefault entry.method;
      mode = lib.mkDefault entry.mode;
      recursive = lib.mkDefault entry.recursive;
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
            then
              formats.render {
                inherit path;
                inherit (entry) format;
                inherit (entry.content) value;
              }
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

  # The live staged entries with build-time bytes, as `tree` entries.
  treeEntries = staged:
    lib.mapAttrs (_path: entry: {
      content.${entry.content._choice} = entry.content.${entry.content._choice};
      inherit (entry) format recursive surface;
    })
    (lib.filterAttrs (_path: entry: builtins.elem entry.content._choice ["source" "text" "value"]) (live staged));
}
