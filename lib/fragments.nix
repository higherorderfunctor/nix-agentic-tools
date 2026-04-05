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
  packageProfiles = {
    ai-clis = {
      dev = {
        common = [
          "coding-standards"
          "commit-convention"
          "tooling-preference"
          "validation"
        ];
        package = [
          "packaging-guide"
        ];
      };
    };

    monorepo = {
      dev = {
        common = [
          "coding-standards"
          "commit-convention"
          "tooling-preference"
          "validation"
        ];
        package = [
          "project-overview"
        ];
      };
    };

    mcp-servers = {
      dev = {
        common = [
          "coding-standards"
          "commit-convention"
          "tooling-preference"
          "validation"
        ];
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
        common = [
          "coding-standards"
          "commit-convention"
          "tooling-preference"
          "validation"
        ];
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
in {
  inherit
    ecosystems
    mkContent
    mkFrontmatter
    mkInstructions
    mkPackageContent
    packagePaths
    packageProfiles
    packagesWithProfile
    readCommon
    readPackage
    ;
}
