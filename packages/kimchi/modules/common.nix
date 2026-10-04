# Opt-in delivery of kimchi-docs (all runtimes) and kimchi-workflow (Kimchi only).
#
# Shared by both backends (`modules/devenv`, `modules/homeManager`); the `ai.*`
# pools are per-`evalModules`, so each backend imports its own instance.
#
# Option surface, following `packages/delegate-routing/modules/common.nix`:
#
#   ai.programs.kimchi-docs.enable            portable, default false
#   ai.<runtime>.programs.kimchi-docs.enable  per-runtime override, null inherits
#   ai.programs.kimchi-workflow.enable        portable, default false
#   ai.kimchi.programs.kimchi-workflow.enable Kimchi-only override, null inherits
#
# kimchi-workflow mounts SKILL.md and its bin link only in ai.kimchi.skills.
#
# and the mount is `ai.<runtime>.skills.kimchi-docs`, written by
# `lib/ai/mkSkillPackageModule.nix` for every runtime whose skills pool exists in
# this evaluation. `ai.skills` keeps its `attrsOf (nullOr path)` type.
#
# kimchi-docs supports EVERY runtime, unlike delegate-routing, which excludes Copilot
# because its sizing controls are not established. Kimchi's documentation is useful to
# any agent working on a kimchi integration, whichever harness it runs in, so the
# `presentSkillRuntimes` filter inside the factory gives the right set on its own
# and no list is hardcoded here.
{
  config,
  lib,
  pkgs,
  options,
  ...
}: let
  mkDocsSkill = import ../lib/mkDocsSkill.nix;
  inherit (import ../../../lib/ai/ai-common.nix {inherit lib;}) resolveOverride;

  # Which search directions SKILL.md carries, resolved per runtime.
  #
  # Operator's rule: MCP-only gets MCP directions; CLI, or CLI+MCP, gets
  # CLI-only directions, because MCP is aimed at runtimes with no shell tool.
  #
  # This reads the semble integration that was actually DELIVERED to the runtime
  # rather than re-resolving `ai.programs.semble.{cli.instructions,mcp}.enable`
  # by hand. Re-resolving would duplicate `featureEnabled` in
  # `packages/semble/modules/common.nix`, whose opt-in/inherit rules are not the
  # plain override rules, and would also have to re-derive the Kiro shape where
  # semble's MCP server is attached to a named agent and is NOT reachable from
  # the root session (`mcp.enable = false` with an MCP-backed subagent). The
  # delivered pools cannot disagree with the options, because semble computes
  # them from exactly those options in its `runtimeConfig`:
  #
  #   ai.<runtime>.rules.semble       written iff `cli.instructions` is selected
  #   ai.<runtime>.mcpServers.semble  written iff `mcp` is selected; an
  #                                   agent-private Kiro server is not written
  #
  # Runtimes semble does not support (copilot, kimchi — `supportedRuntimes` in
  # `packages/semble/modules/options.nix`) simply have neither entry and fall
  # through to `plain`.
  delivered = runtime: pool:
    lib.attrByPath ["ai" runtime pool "semble"] null config != null;
  searchFor = runtime:
    if delivered runtime "rules"
    then "cli"
    else if delivered runtime "mcpServers"
    then "mcp"
    else "plain";
in {
  config = lib.mkIf (lib.hasAttrByPath ["ai" "kimchi" "programs" "delegate-routing"] options) {
    ai.kimchi.programs.delegate-routing.techniques.kimchi-workflow-run.enable = lib.mkDefault (
      resolveOverride {
        topValue = config.ai.programs.kimchi-workflow.enable;
        cliValue = config.ai.kimchi.programs.kimchi-workflow.enable;
      }
    );
  };

  imports = [
    (import ../../../lib/ai/mkSkillPackageModule.nix {
      name = "kimchi-docs";
      enableDescription = "the pinned Kimchi documentation snapshot as a searchable skill";
      skills = {runtime, ...}: {
        kimchi-docs = "${mkDocsSkill {
          inherit lib pkgs;
          docs = config.ai.internal.roots.docs.kimchi-docs;
          search = searchFor runtime;
          treefmt-nix = config.ai.internal.treefmtNix;
        }}";
      };
    })
    (import ../../../lib/ai/mkSkillPackageModule.nix {
      name = "kimchi-workflow";
      enableDescription = "the headless Kimchi workflow launch and result skill";
      supportedRuntimes = ["kimchi"];
      skills = {pkgs, ...}: {
        kimchi-workflow = "${import ../lib/mkWorkflowSkill.nix {inherit pkgs;}}";
      };
    })
  ];
}
