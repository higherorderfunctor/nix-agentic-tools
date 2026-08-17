# Generated option-documentation parity check.
#
# The old mdbook/NuschtOS site was deliberately removed, but
# lib/options-doc.nix remains the canonical evaluator for consumer-facing HM
# and devenv option references. Building both renderings here gives that code a
# live owner and catches four easy-to-miss regressions:
#
#   1. either backend adds, removes, or retypes any `ai.*` option without the
#      matching change in the other backend;
#   2. Codex loses one of the reviewed top-level surfaces completed by the
#      configuration-parity roadmap; and
#   3. a shared-pool description silently forgets either Codex support or a
#      deliberate runtime exclusion; and
#   4. the retired normalized `instructions` surface reappears while preserving
#      otherwise exact HM/devenv parity.
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
  # The shared runtime registry. This site used to hardcode a FOUR-element list
  # without kimchi, which was a coverage gap rather than an exclusion: kimchi's
  # HM and devenv facets predate this check by about six weeks, and nothing
  # here ever mentioned it. Adding it is a strict tightening — both assertions
  # were measured passing before the substitution.
  runtimes = import ../lib/ai/runtimes.nix;
  devenvJson = "${docs.devenvOptionsDoc.optionsJSON}/share/doc/nixos/options.json";
  hmJson = "${docs.hmOptionsDoc.optionsJSON}/share/doc/nixos/options.json";
  expectedCodexRoots = pkgs.writeText "expected-codex-option-roots" (
    lib.concatStringsSep "\n" [
      "ai.codex.agents"
      "ai.codex.configDir"
      "ai.codex.context"
      "ai.codex.enable"
      "ai.codex.environmentVariables"
      "ai.codex.execpolicyRules"
      "ai.codex.files"
      "ai.codex.hooks"
      "ai.codex.mcpServers"
      "ai.codex.nativeSettings"
      "ai.codex.package"
      "ai.codex.profiles"
      "ai.codex.programs"
      "ai.codex.projectDocMaxBytes"
      "ai.codex.rules"
      "ai.codex.rulesDir"
      "ai.codex.settings"
      "ai.codex.shell"
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
    "ai.lspServers"
    "ai.mcpServers"
    "ai.rules"
    "ai.rulesDir"
    # Its whole contract is which runtimes it reaches, and Codex is the one
    # that needed a launcher wrapper built to receive it — a description that
    # stops naming Codex has stopped being true.
    "ai.shell"
    "ai.skills"
    "ai.skillsDir"
  ];
  sharedDescriptionsThatMustDiscussKimchi = [
    "ai.context"
    "ai.mcpServers"
    "ai.rules"
    "ai.skills"
    "ai.skillsDir"
  ];
  copilotDescriptionsThatMustDiscussHmNoop = [
    "ai.copilot.context"
    "ai.copilot.rules"
  ];
in {
  options-doc-ai-parity = pkgs.runCommand "options-doc-ai-parity" {} ''
    diff="${lib.getExe' pkgs.diffutils "diff"}"
    grep="${lib.getExe pkgs.gnugrep}"
    jq="${lib.getExe pkgs.jq}"
    sort="${lib.getExe' pkgs.coreutils "sort"}"

    # Flattened names catch missing leaves (not only missing top-level roots),
    # while the normalized type map catches a declaration that still exists
    # but accepts a different value shape in one backend. Defaults and
    # descriptions may intentionally differ with lifecycle/scope, so they are
    # documented and behavior-tested rather than mechanically equated here.
    "$jq" -r '
      keys[]
      | select(startswith("ai."))
    ' "${hmJson}" | "$sort" -u > hm-ai-options
    "$jq" -r '
      keys[]
      | select(startswith("ai."))
    ' "${devenvJson}" | "$sort" -u > devenv-ai-options
    "$diff" -u hm-ai-options devenv-ai-options

    "$jq" -S '
      with_entries(select(.key | startswith("ai.")))
      | map_values({ type: .type })
    ' "${hmJson}" > hm-ai-types.json
    "$jq" -S '
      with_entries(select(.key | startswith("ai.")))
      | map_values({ type: .type })
    ' "${devenvJson}" > devenv-ai-types.json
    "$diff" -u hm-ai-types.json devenv-ai-types.json

    "$jq" -r '
      keys[]
      | select(startswith("ai.codex."))
      | split(".")[0:3]
      | join(".")
    ' "${hmJson}" | "$sort" -u > actual-codex-option-roots
    "$diff" -u "${expectedCodexRoots}" actual-codex-option-roots

    # Semantic-agent `.instructions` fields and Semble's nested program feature
    # remain valid. Only the normalized root and per-runtime guidance surface
    # was retired.
    ${lib.concatMapStringsSep "\n" (name: ''
        ! "$jq" --exit-status --arg name "${name}" 'has($name)' "${hmJson}" >/dev/null
        ! "$jq" --exit-status --arg name "${name}" 'has($name)' "${devenvJson}" >/dev/null
      '')
      (["ai.instructions"] ++ map (runtime: "ai.${runtime}.instructions") runtimes)}

    # Internal module-to-runtime channels must remain absent from both
    # consumer-facing references even though they are declared symmetrically.
    ! "$grep" -Fq '_integration_writable_roots' "${hmJson}"
    ! "$grep" -Fq '_integration_writable_roots' "${devenvJson}"
    ! "$grep" -Fq '_integration_writable_roots' "${docs.hmOptionsDoc.optionsCommonMark}"
    ! "$grep" -Fq '_integration_writable_roots' "${docs.devenvOptionsDoc.optionsCommonMark}"

    # Devenv-only service APIs still belong in the consumer reference. This
    # positive control prevents an omitted transform prefix from silently
    # filtering the complete Beads module tree.
    "$jq" --exit-status 'has("services.beads.enable")' "${devenvJson}" >/dev/null
    "$grep" -Fq 'services\.beads\.enable' "${docs.devenvOptionsDoc.optionsCommonMark}"

    # Exercise every runtime namespace in the CommonMark renderings too; JSON
    # parity alone would let a broken markdown generator remain dormant after
    # the doc-site removal. nixos-render-docs escapes dots in option headings.
    ${lib.concatMapStringsSep "\n" (app: ''
        "$grep" -Fq 'ai\.${app}\.enable' "${docs.hmOptionsDoc.optionsCommonMark}"
        "$grep" -Fq 'ai\.${app}\.enable' "${docs.devenvOptionsDoc.optionsCommonMark}"
      '')
      runtimes}

    ${lib.concatMapStringsSep "\n" (name: ''
        "$jq" --exit-status --arg name "${name}" \
          '.[$name].description | contains("Codex")' "${hmJson}" >/dev/null
        "$jq" --exit-status --arg name "${name}" \
          '.[$name].description | contains("Codex")' "${devenvJson}" >/dev/null
      '')
      sharedDescriptionsThatMustDiscussCodex}

    ${lib.concatMapStringsSep "\n" (name: ''
        "$jq" --exit-status --arg name "${name}" \
          '.[$name].description | contains("Kimchi")' "${hmJson}" >/dev/null
        "$jq" --exit-status --arg name "${name}" \
          '.[$name].description | contains("Kimchi")' "${devenvJson}" >/dev/null
      '')
      sharedDescriptionsThatMustDiscussKimchi}

    ${lib.concatMapStringsSep "\n" (name: ''
        "$jq" --exit-status --arg name "${name}" \
          '.[$name].description | contains("Home Manager") and contains("no-op")' "${hmJson}" >/dev/null
        "$jq" --exit-status --arg name "${name}" \
          '.[$name].description | contains("Home Manager") and contains("no-op")' "${devenvJson}" >/dev/null
      '')
      copilotDescriptionsThatMustDiscussHmNoop}

    # The successful check output is also the requested machine-readable parity
    # report: one complete, sorted contract shared by both backends.
    cp hm-ai-options "$out"
  '';
}
