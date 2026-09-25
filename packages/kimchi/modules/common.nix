# Opt-in delivery of the pinned kimchi documentation snapshot as a skill.
#
# Shared by both backends (`modules/devenv`, `modules/homeManager`); the `ai.*`
# pools are per-`evalModules`, so each backend imports its own instance.
#
# Option surface, following `packages/delegate-sizing/modules/common.nix`:
#
#   ai.programs.kimchi-docs.enable            portable, default false
#   ai.<runtime>.programs.kimchi-docs.enable  per-runtime override, null inherits
#
# and the mount is `ai.<runtime>.skills.kimchi-docs`, written by
# `lib/ai/mkSkillPackageModule.nix` for every runtime whose skills pool exists in
# this evaluation. `ai.skills` keeps its `attrsOf (nullOr path)` type.
#
# EVERY runtime is supported, unlike delegate-sizing, which excludes kimchi
# because kimchi has no delegate primitive. Kimchi's documentation is useful to
# any agent working on a kimchi integration, whichever harness it runs in, so the
# `presentSkillRuntimes` filter inside the factory gives the right set on its own
# and no list is hardcoded here.
{
  config,
  lib,
  pkgs,
  ...
}: let
  mkDocsSkill = import ../lib/mkDocsSkill.nix;

  # Which search directions SKILL.md carries, resolved per runtime.
  #
  # Operator's rule: MCP-only gets MCP directions; CLI, or CLI+MCP, gets
  # CLI-only directions, because MCP is aimed at runtimes with no shell tool.
  #
  # This reads the semble integration that was actually DELIVERED to the runtime
  # rather than re-resolving `ai.programs.semble.{cli.instructions,mcp}.enable`
  # by hand. Re-resolving would duplicate `featureEnabled`
  # (`packages/semble/modules/common.nix:37-53`), whose opt-in/inherit rules are
  # not the plain override rules, and would also miss
  # `mcp.rootExposure = false` — the Kiro shape where semble's MCP server is
  # attached to a named agent and is NOT reachable from the root session
  # (`packages/semble/modules/options.nix:186`, written at
  # `packages/semble/modules/common.nix:263`). The delivered pools cannot
  # disagree with the options, because semble computes them from exactly those
  # options:
  #
  #   ai.<runtime>.rules.semble       written iff `cli.instructions` is selected
  #                                   (common.nix:260, options.nix:138)
  #   ai.<runtime>.mcpServers.semble  written iff `mcp` is selected AND exposed
  #                                   to the root session (common.nix:263)
  #
  # Runtimes semble does not support (copilot, kimchi — `options.nix:110`) simply
  # have neither entry and fall through to `plain`.
  delivered = runtime: pool:
    lib.attrByPath ["ai" runtime pool "semble"] null config != null;
  searchFor = runtime:
    if delivered runtime "rules"
    then "cli"
    else if delivered runtime "mcpServers"
    then "mcp"
    else "plain";
in {
  imports = [
    (import ../../../lib/ai/mkSkillPackageModule.nix {
      name = "kimchi-docs";
      enableDescription = "the pinned Kimchi documentation snapshot as a searchable skill";
      skills = {runtime, ...}: {
        kimchi-docs = "${mkDocsSkill {
          inherit lib pkgs;
          docs = pkgs.docs.kimchi-docs;
          search = searchFor runtime;
        }}";
      };
    })
  ];
}
