# Fragment-based instruction generation (monorepo-extended).
#
# Single source of truth for which fragments compose each profile
# and how each ecosystem wraps the output (frontmatter, paths).
#
# Directory layout:
#   fragments/common/*.md          — shared across all packages
#   fragments/packages/<pkg>/*.md  — package-specific
#
# Usage:
#   lib.mkInstructions { package = "monorepo"; profile = "dev"; ecosystem = "claude"; }
#   lib.mkInstructions { package = "stacked-workflows"; profile = "package"; ecosystem = "kiro"; }
{lib}: let
  fragmentsDir = ../fragments;

  # -- Fragment reading --------------------------------------------------------

  readCommon = name:
    builtins.readFile "${fragmentsDir}/common/${name}.md";

  readPackage = package: name:
    builtins.readFile "${fragmentsDir}/packages/${package}/${name}.md";

  # -- Package profiles --------------------------------------------------------

  # Each package declares which fragments compose each profile.
  # "common" lists reference fragments/common/*.md.
  # "package" lists reference fragments/packages/<pkg>/*.md.

  # Shared common fragments for all dev profiles (DRY extraction).
  devCommonFragments = [
    "coding-standards"
    "commit-convention"
    "config-parity"
    "tooling-preference"
    "validation"
  ];

  packageProfiles = {
    ai-clis = {
      dev = {
        common = devCommonFragments;
        package = [
          "packaging-guide"
        ];
      };
    };

    monorepo = {
      dev = {
        common = devCommonFragments;
        package = [
          "project-overview"
        ];
      };
    };

    mcp-servers = {
      dev = {
        common = devCommonFragments;
        package = [
          "overlay-guide"
        ];
      };
    };

    stacked-workflows = {
      # Consumer install — what users need to USE the skills
      package = {
        common = [];
        package = [
          "routing-table"
        ];
      };
      dev = {
        common = devCommonFragments;
        package = [
          "development"
          "routing-table"
        ];
      };
    };
  };

  # -- Path scoping per package ------------------------------------------------

  # Maps package names to the file paths they govern (for ecosystem frontmatter).
  packagePaths = {
    ai-clis = ''"modules/copilot-cli/**,modules/kiro-cli/**,packages/ai-clis/**"'';
    mcp-servers = ''"modules/mcp-servers/**,packages/mcp-servers/**"'';
    monorepo = null; # root — no path restriction
    stacked-workflows = ''"skills/**,references/**,fragments/packages/stacked-workflows/**"'';
  };

  # -- Ecosystems --------------------------------------------------------------

  ecosystems = {
    agentsmd = {
      # AGENTS.md — no frontmatter
      mkFrontmatter = _package: null;
    };
    claude = {
      # Claude rules: paths frontmatter for per-package scoping
      mkFrontmatter = package: let
        paths = packagePaths.${package} or null;
      in
        if paths == null
        then null
        else {
          description = "Instructions for the ${package} package";
          inherit paths;
        };
    };
    copilot = {
      # Copilot instructions: applyTo frontmatter
      mkFrontmatter = package: let
        paths = packagePaths.${package} or null;
      in
        if paths == null
        then {applyTo = ''"**"'';}
        else {applyTo = paths;};
    };
    kiro = {
      # Kiro steering: inclusion mode + fileMatchPattern
      mkFrontmatter = package: let
        paths = packagePaths.${package} or null;
      in
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
  };

  # -- Builders ----------------------------------------------------------------

  # Concatenate fragments for a package profile
  mkContent = {
    package,
    profile,
  }: let
    prof = packageProfiles.${package}.${profile};
    commonFragments = map readCommon prof.common;
    packageFragments = map (readPackage package) prof.package;
  in
    builtins.concatStringsSep "\n" (commonFragments ++ packageFragments);

  # Package-specific content only (no common fragments) — for AGENTS.md dedup
  mkPackageContent = {
    package,
    profile,
  }: let
    prof = packageProfiles.${package}.${profile};
    packageFragments = map (readPackage package) prof.package;
  in
    builtins.concatStringsSep "\n" packageFragments;

  # Build YAML frontmatter block from an attrset
  mkFrontmatter = attrs:
    "---\n"
    + builtins.concatStringsSep "\n"
    (lib.mapAttrsToList (k: v: "${k}: ${v}") attrs)
    + "\n---\n";

  # Build final output: optional frontmatter + concatenated fragments
  mkInstructions = {
    ecosystem,
    package,
    profile,
  }: let
    content = mkContent {inherit package profile;};
    fm = ecosystems.${ecosystem}.mkFrontmatter package;
  in
    if fm == null
    then content
    else mkFrontmatter fm + "\n" + content;

  # List all packages that have a given profile
  packagesWithProfile = profile:
    lib.filterAttrs (_: profiles: profiles ? ${profile})
    packageProfiles;

  # -- Typed fragment constructors and composition -----------------------------

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

  # Typed wrapper around readCommon — returns a fragment with priority 10.
  readCommonFragment = name:
    mkFragment {
      text = readCommon name;
      description = "common/${name}";
      priority = 10;
    };

  # Typed wrapper around readPackage — returns a fragment with priority 5.
  readPackageFragment = package: name:
    mkFragment {
      text = readPackage package name;
      description = "packages/${package}/${name}";
      priority = 5;
    };
in {
  inherit
    compose
    ecosystems
    mkContent
    mkFragment
    mkFrontmatter
    mkInstructions
    mkPackageContent
    packagePaths
    packageProfiles
    packagesWithProfile
    readCommon
    readCommonFragment
    readPackage
    readPackageFragment
    ;
}
