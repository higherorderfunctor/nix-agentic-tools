# Fragment composition for instruction file generation.
#
# Single source of truth for composing dev-only fragments into
# ecosystem-specific instruction files. Consumed by both devenv tasks
# and flake derivations.
#
# Takes { lib, pkgs } where pkgs has the content overlays applied:
# - fragments-ai (transforms)
# - coding-standards (commonFragments)
# - stacked-workflows (swsFragments via stacked-workflows-content)
#
# Returns:
#   agentsMd     — full AGENTS.md content string
#   claudeFiles  — { "filename.md" = content; } for Claude rule files
#   claudeMd     — full CLAUDE.md content string
#   copilotFiles — { "filename.md" = content; } for Copilot files
#   kiroFiles    — { "filename.md" = content; } for Kiro steering files
#
# Future chunks add:
#   - Per-ecosystem dev fragments (ai-clis, claude-code, hm-modules,
#     mcp-servers, overlays, devenv, stacked-workflows, ai-module,
#     ai-skills) extend devFragmentNames and packagePaths
#   - README.md / CONTRIBUTING.md generators add `repo-readme` /
#     `repo-contributing` derivations alongside the existing
#     `instructions-*` set
{
  lib,
  pkgs,
}: let
  fragments = import ../lib/fragments.nix {inherit lib;};

  # ── Fragments from content packages (via overlay) ────────────────────
  # commonFragments is the always-loaded coding standards set, merged
  # into the monorepo profile only (scoped profiles are intentionally
  # lean to avoid context-rot duplication against the always-loaded
  # common.md / CLAUDE.md content).
  commonFragments = builtins.attrValues pkgs.coding-standards.passthru.fragments;
  # swsFragments is the published stacked-workflows content set
  # (currently the routing-table fragment). Per category, callers
  # opt in via extraPublishedFragments below.
  swsFragments = builtins.attrValues pkgs.stacked-workflows-content.passthru.fragments;

  # ── Dev-only fragment reader ─────────────────────────────────────────
  # Each entry in devFragmentNames may be either:
  #   - A bare string "name" (legacy form, equivalent to location = "dev")
  #     reads ./fragments/<pkg>/<name>.md
  #   - An attrset { location, name, dir ? pkg } for co-located fragments:
  #     - location = "dev" (default): ./fragments/<dir>/<name>.md
  #     - location = "package": ../packages/<dir>/fragments/dev/<name>.md
  #     - location = "module":  ../modules/<dir>/fragments/dev/<name>.md
  #     The `dir` field defaults to `pkg` (the devFragmentNames key) but can
  #     be set explicitly when the category name differs from the directory
  #     name (e.g., category "ai-module" pointing at modules/ai/).
  mkDevFragment = pkg: entry: let
    normalized =
      if builtins.isString entry
      then {
        location = "dev";
        name = entry;
        dir = pkg;
      }
      else {
        location = entry.location or "dev";
        inherit (entry) name;
        dir = entry.dir or pkg;
      };
    inherit (normalized) location name dir;
    fragmentPath =
      if location == "dev"
      then ./fragments + "/${dir}/${name}.md"
      else if location == "package"
      then ../packages + "/${dir}/fragments/dev/${name}.md"
      else if location == "module"
      then ../modules + "/${dir}/fragments/dev/${name}.md"
      else throw "mkDevFragment: unknown location '${location}' (expected dev|package|module)";
  in
    fragments.mkFragment {
      text = builtins.readFile fragmentPath;
      description = "${location}:${dir}/${name}";
      priority = 5;
    };

  # ── Package path scoping (for ecosystem frontmatter) ─────────────────
  # Lists are the canonical form. The fragments-ai transforms handle
  # per-ecosystem emission: Claude as a YAML list, Copilot as a
  # comma-joined string (native applyTo syntax), Kiro as an inline
  # YAML array (native fileMatchPattern multi-pattern syntax).
  # null means "always-loaded" (no scoping).
  packagePaths = {
    flake = [
      "flake.nix"
      "devenv.nix"
    ];
    monorepo = null;
    nix-standards = ["**/*.nix"];
    packaging = [
      "nvfetcher.toml"
      "packages/**/*.nix"
      "packages/**/sources.nix"
    ];
    pipeline = [
      "lib/fragments.nix"
      "dev/generate.nix"
      "dev/tasks/generate.nix"
      "packages/fragments-ai/**"
    ];
  };

  # ── Dev fragment names per package ───────────────────────────────────
  # Reduced for Chunk 3 — only categories whose source files exist on
  # this branch. Later chunks ADD entries as their dev fragments land.
  devFragmentNames = {
    flake = ["binary-cache"];
    monorepo = [
      "architecture-fragments"
      "build-commands"
      "change-propagation"
      "linting"
      "project-overview"
    ];
    nix-standards = ["nix-standards"];
    packaging = [
      "naming-conventions"
      "platforms"
    ];
    pipeline = [
      "fragment-pipeline"
      "generation-architecture"
    ];
  };

  # ── Extra published fragments per package (beyond commonFragments) ───
  # Categories may opt into additional published fragment sets on top of
  # the dev fragments. The monorepo profile gets the SWS routing table
  # so it shows up in always-loaded CLAUDE.md / common.md.
  extraPublishedFragments = {
    monorepo = swsFragments;
  };

  # ── Compose fragments for a dev package profile ──────────────────────
  # The monorepo (root) profile prepends always-loaded coding standards
  # (commonFragments) so they appear in CLAUDE.md / common.md once.
  # Scoped profiles include ONLY their scope-specific content — repeating
  # commonFragments in every scoped rule file amplifies context rot
  # (duplicate tokens loaded when a scoped rule triggers alongside the
  # always-loaded common.md).
  mkDevComposed = package: let
    devFrags = map (mkDevFragment package) (devFragmentNames.${package} or []);
    extraFrags = extraPublishedFragments.${package} or [];
    isRoot = package == "monorepo";
  in
    fragments.compose {
      fragments =
        if isRoot
        then commonFragments ++ extraFrags ++ devFrags
        else extraFrags ++ devFrags;
    };

  # ── Ecosystem file transforms ────────────────────────────────────────
  aiTransforms = pkgs.fragments-ai.passthru.transforms;
  mkEcosystemFile = package: let
    paths = packagePaths.${package} or null;
    withPaths = composed:
      if paths != null
      then composed // {inherit paths;}
      else composed;
  in {
    agentsmd = composed: aiTransforms.agentsmd (withPaths composed);
    claude = composed: aiTransforms.claude {inherit package;} (withPaths composed);
    copilot = composed: aiTransforms.copilot (withPaths composed);
    kiro = composed: aiTransforms.kiro {name = package;} (withPaths composed);
  };

  # ── Derived values ───────────────────────────────────────────────────
  nonRootPackages = lib.filterAttrs (name: _: name != "monorepo") devFragmentNames;
  rootComposed = mkDevComposed "monorepo";
  monorepoEco = mkEcosystemFile "monorepo";

  # ── AGENTS.md content ────────────────────────────────────────────────
  # AGENTS.md is orientation only. Flat consumers (Codex, generic
  # agents.md-compatible tooling) get orientation; deep-dive
  # architecture fragments load via per-ecosystem scoped files for
  # Claude/Copilot/Kiro.
  agentsContent = rootComposed.text;

  # ── Claude rule files ────────────────────────────────────────────────
  # Scoped rule files only. No common.md — the body content is
  # already loaded via CLAUDE.md (which @-imports AGENTS.md).
  claudeFiles =
    lib.concatMapAttrs (pkg: _: let
      composed = mkDevComposed pkg;
      pkgEco = mkEcosystemFile pkg;
    in {
      "${pkg}.md" = pkgEco.claude composed;
    })
    nonRootPackages;

  # ── Copilot instruction files ────────────────────────────────────────
  copilotFiles =
    {
      "copilot-instructions.md" = monorepoEco.copilot rootComposed;
    }
    // (lib.concatMapAttrs (pkg: _: let
        composed = mkDevComposed pkg;
        pkgEco = mkEcosystemFile pkg;
      in {
        "${pkg}.instructions.md" = pkgEco.copilot composed;
      })
      nonRootPackages);

  # ── Kiro steering files ─────────────────────────────────────────────
  # `common.md` is always-loaded (no `paths`). Pass an explicit
  # description so the transform doesn't omit it (per the transform's
  # "no description for paths==null without explicit override" rule).
  kiroFiles =
    {
      "common.md" =
        aiTransforms.kiro {name = "common";}
        (rootComposed
          // {
            description = "Always-loaded monorepo orientation for Kiro.";
          });
    }
    // (lib.concatMapAttrs (pkg: _: let
        composed = mkDevComposed pkg;
        pkgEco = mkEcosystemFile pkg;
      in {
        "${pkg}.md" = pkgEco.kiro composed;
      })
      nonRootPackages);

  # ── Top-level markdown files ─────────────────────────────────────────
  agentsMd = ''
    # AGENTS.md

    Project instructions for AI coding assistants working in this repository.
    Read by Claude Code, Kiro, GitHub Copilot, Codex, and other tools that
    support the [AGENTS.md standard](https://agents.md).

    Deep-dive architecture documentation lives in path-scoped per-ecosystem
    files (`.claude/rules/<name>.md`,
    `.github/instructions/<name>.instructions.md`,
    `.kiro/steering/<name>.md`). Those files load on demand when editing
    matching paths; they are not duplicated here to keep this file small.

    ${agentsContent}
  '';

  # CLAUDE.md is a one-liner that @-imports AGENTS.md. All
  # orientation content lives in AGENTS.md. Keeping CLAUDE.md
  # body content alongside the @AGENTS.md import would
  # double-load the content at every session start.
  claudeMd = ''
    # CLAUDE.md

    @AGENTS.md
  '';
in {
  inherit agentsMd claudeFiles claudeMd copilotFiles kiroFiles;
}
