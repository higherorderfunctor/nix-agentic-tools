# Generated option-documentation parity check.
#
# The old mdbook/NuschtOS site was deliberately removed, but
# lib/options-doc.nix remains the canonical evaluator for consumer-facing HM
# and devenv option references. Building both renderings here gives that code a
# live owner and catches two easy-to-miss regressions:
#
#   1. a backend declares a Codex option that the other backend omits; and
#   2. a shared-pool description says "every app" while silently forgetting
#      either Codex support or an intentional Codex exclusion.
#
# Exact option-tree parity is appropriate here even where runtime behavior
# differs. Backend-specific boundaries such as Home Manager-only profile
# materialization are represented by assertions/defaults, not by deleting the
# option from devenv; that keeps discovery and diagnostics consistent.
{
  lib,
  pkgs,
  self,
}: let
  docs = import ../lib/options-doc.nix {inherit lib pkgs self;};
  devenvJson = "${docs.devenvOptionsDoc.optionsJSON}/share/doc/nixos/options.json";
  hmJson = "${docs.hmOptionsDoc.optionsJSON}/share/doc/nixos/options.json";
  expectedCodexRoots = pkgs.writeText "expected-codex-option-roots" (
    lib.concatStringsSep "\n" [
      "ai.codex.agents"
      "ai.codex.configDir"
      "ai.codex.context"
      "ai.codex.enable"
      "ai.codex.execpolicyRules"
      "ai.codex.hooks"
      "ai.codex.instructions"
      "ai.codex.mcpServers"
      "ai.codex.package"
      "ai.codex.profiles"
      "ai.codex.projectDocMaxBytes"
      "ai.codex.rules"
      "ai.codex.rulesDir"
      "ai.codex.settings"
      "ai.codex.skills"
      "ai.codex.skillsDir"
    ]
    + "\n"
  );
  sharedDescriptionsThatMustDiscussCodex = [
    "ai.agents"
    "ai.agentsDir"
    "ai.context"
    "ai.environmentVariables"
    "ai.hooks"
    "ai.instructions"
    "ai.lspServers"
    "ai.mcpServers"
    "ai.rules"
    "ai.rulesDir"
    "ai.skills"
    "ai.skillsDir"
  ];
in {
  options-doc-codex-parity = pkgs.runCommand "options-doc-codex-parity" {} ''
    diff="${lib.getExe' pkgs.diffutils "diff"}"
    grep="${lib.getExe pkgs.gnugrep}"
    jq="${lib.getExe pkgs.jq}"
    sort="${lib.getExe' pkgs.coreutils "sort"}"

    "$jq" -r '
      keys[]
      | select(startswith("ai.codex."))
    ' "${hmJson}" | "$sort" -u > hm-codex-options
    "$jq" -r '
      keys[]
      | select(startswith("ai.codex."))
    ' "${devenvJson}" | "$sort" -u > devenv-codex-options
    "$diff" -u hm-codex-options devenv-codex-options

    "$jq" -r '
      keys[]
      | select(startswith("ai.codex."))
      | split(".")[0:3]
      | join(".")
    ' "${hmJson}" | "$sort" -u > actual-codex-option-roots
    "$diff" -u "${expectedCodexRoots}" actual-codex-option-roots

    # Exercise the CommonMark renderings too; JSON parity alone would let a
    # broken markdown generator remain dormant after the doc-site removal.
    # nixos-render-docs escapes dots in option headings for mdbook anchors.
    "$grep" -Fq 'ai\.codex\.enable' "${docs.hmOptionsDoc.optionsCommonMark}"
    "$grep" -Fq 'ai\.codex\.enable' "${docs.devenvOptionsDoc.optionsCommonMark}"

    ${lib.concatMapStringsSep "\n" (name: ''
        "$jq" --exit-status --arg name "${name}" \
          '.[$name].description | contains("Codex")' "${hmJson}" >/dev/null
        "$jq" --exit-status --arg name "${name}" \
          '.[$name].description | contains("Codex")' "${devenvJson}" >/dev/null
      '')
      sharedDescriptionsThatMustDiscussCodex}

    cp hm-codex-options "$out"
  '';
}
