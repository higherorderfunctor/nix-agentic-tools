# Pure fragment composition library.
#
# Provides typed fragment constructors, composition (sort + dedup),
# YAML frontmatter generation, and a render hook for transforms.
#
# All functions are pure — no file I/O, no hardcoded paths, no data.
# Callers supply fragments from package passthru or builtins.readFile.
#
# Usage:
#   fragments.compose { fragments = [...]; }
#   fragments.render { composed = ...; transform = ...; }
{lib}: let
  # -- Builders ----------------------------------------------------------------
  # Build YAML frontmatter block from an attrset.
  mkFrontmatter = attrs:
    "---\n"
    + builtins.concatStringsSep "\n"
    (lib.mapAttrsToList (k: v: "${k}: ${v}") attrs)
    + "\n---\n";

  # Canonical fragment constructor.
  # Returns a normalized attrset with all fields defaulted:
  #   { text, description, paths, priority }
  mkFragment = {
    text,
    description ? null,
    paths ? null,
    priority ? 0,
  }: {
    inherit description paths priority text;
  };

  # Compose a list of fragments into a single fragment.
  # Sorts by priority descending (higher = earlier), deduplicates by text
  # content hash, then concatenates into a single mkFragment.
  # Optional overrides (description, paths, priority) name the output fragment.
  compose = {
    fragments,
    description ? null,
    paths ? null,
    priority ? 0,
  }: let
    sorted = lib.sort (a: b: a.priority > b.priority) fragments;
    deduped =
      builtins.foldl' (
        acc: frag: let
          key = builtins.hashString "sha256" frag.text;
          inherit (acc) seen;
        in
          if seen ? ${key}
          then acc
          else {
            seen = seen // {"${key}" = true;};
            result = acc.result ++ [frag];
          }
      ) {
        seen = {};
        result = [];
      }
      sorted;
    combined = builtins.concatStringsSep "\n" (map (f: f.text) deduped.result);
  in
    mkFragment {
      inherit description paths priority;
      text = combined;
    };

  # Apply a transform to a composed fragment.
  # transform is a curried function: fragment -> string
  render = {
    composed,
    transform,
  }:
    transform composed;
in {
  inherit compose mkFragment mkFrontmatter render;
}
