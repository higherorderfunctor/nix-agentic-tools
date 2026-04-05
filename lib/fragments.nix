# Pure fragment composition library.
#
# Provides typed fragment constructors, composition (sort + dedup),
# YAML frontmatter generation, and per-ecosystem content wrappers.
#
# All functions are pure — no file I/O, no hardcoded paths, no data.
# Callers supply fragments from package passthru or builtins.readFile.
#
# Usage:
#   fragments.compose { fragments = [...]; }
#   fragments.mkEcosystemContent { ecosystem = "claude"; package = "foo"; composed = ...; paths = ...; }
{lib}: let
  # -- Ecosystems --------------------------------------------------------------
  # Frontmatter generators per ecosystem. Each takes (paths, package) and
  # returns an attrset for mkFrontmatter, or null for no frontmatter.
  ecosystems = {
    agentsmd.mkFrontmatter = _paths: _package: null;
    claude.mkFrontmatter = paths: package:
      if paths == null
      then null
      else {
        description = "Instructions for the ${package} package";
        inherit paths;
      };
    copilot.mkFrontmatter = paths: _package:
      if paths == null
      then {applyTo = ''"**"'';}
      else {applyTo = paths;};
    kiro.mkFrontmatter = paths: package:
      if paths == null
      then {
        description = "Shared coding standards and conventions";
        inclusion = "always";
        name = "common";
      }
      else {
        description = "Instructions for the ${package} package";
        fileMatchPattern = paths;
        inclusion = "fileMatch";
        name = package;
      };
  };

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

  # Apply ecosystem frontmatter to a composed fragment.
  # Extracts the pattern duplicated across devenv.nix and flake.nix.
  mkEcosystemContent = {
    ecosystem,
    package,
    composed,
    paths ? null,
  }: let
    fm = ecosystems.${ecosystem}.mkFrontmatter paths package;
    fmStr =
      if fm == null
      then ""
      else mkFrontmatter fm + "\n";
  in
    fmStr + composed.text;
in {
  inherit compose ecosystems mkEcosystemContent mkFragment mkFrontmatter;
}
