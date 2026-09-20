# Generated option-documentation parity check.
#
# The old mdbook/NuschtOS site was deliberately removed, but
# lib/options-doc.nix remains the canonical evaluator for consumer-facing HM
# and devenv option references. Building both renderings here gives that code a
# live owner and catches five easy-to-miss regressions:
#
#   1. either backend adds, removes, or retypes any `ai.*` option without the
#      matching change in the other backend;
#   2. Codex loses one of the reviewed top-level surfaces completed by the
#      configuration-parity roadmap; and
#   3. a shared-pool description silently forgets either Codex support or a
#      deliberate runtime exclusion; and
#   4. the retired normalized `instructions` surface reappears while preserving
#      otherwise exact HM/devenv parity; and
#   5. a native settings option leaves `ai.<runtime>.native`, or a retired
#      flat name (`nativeSettings`, Kimchi's `harnessSettings`) comes back.
#
# Every guard goes through one of the shell helpers at the top of the build,
# so a failure names the guard, the option or text, and which rendering
# tripped it; a bare `jq --exit-status` or `grep -q` would fail the build with
# an empty log.
#
# Exact option-tree parity is appropriate here even where runtime behavior
# differs. Backend-specific boundaries are represented by assertions/defaults,
# not by deleting the option from either backend; that keeps discovery and
# diagnostics consistent.
{
  lib,
  pkgs,
  self,
  ...
}: {
  checks = let
    docs = import ../../lib/options-doc.nix {inherit lib pkgs self;};
    # The shared runtime registry. This site used to hardcode a FOUR-element list
    # without kimchi, which was a coverage gap rather than an exclusion: kimchi's
    # HM and devenv facets predate this check by about six weeks, and nothing
    # here ever mentioned it. Adding it is a strict tightening — both assertions
    # were measured passing before the substitution.
    runtimes = import ../../lib/ai/runtimes.nix;
    devenvJson = "${docs.devenvOptionsDoc.optionsJSON}/share/doc/nixos/options.json";
    hmJson = "${docs.hmOptionsDoc.optionsJSON}/share/doc/nixos/options.json";
    expectedCodexRoots = pkgs.writeText "expected-codex-option-roots" (
      lib.concatStringsSep "\n" [
        "ai.codex.activation"
        "ai.codex.agents"
        "ai.codex.configDir"
        "ai.codex.context"
        "ai.codex.enable"
        "ai.codex.environmentVariables"
        "ai.codex.execpolicyRules"
        "ai.codex.files"
        "ai.codex.hooks"
        "ai.codex.mcpServers"
        "ai.codex.methodFor"
        "ai.codex.native"
        "ai.codex.normalized"
        "ai.codex.package"
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
      "ai.agents"
      "ai.agentsDir"
      "ai.context"
      "ai.hooks"
      "ai.mcpServers"
      "ai.rules"
      "ai.skills"
      "ai.skillsDir"
    ];
    copilotDescriptionsThatMustDiscussHmWarning = [
      "ai.copilot.context"
      "ai.copilot.rules"
    ];
    # Each rendering with the role its failure message names.
    hmJsonDoc = {
      role = "HM options JSON";
      path = hmJson;
    };
    devenvJsonDoc = {
      role = "devenv options JSON";
      path = devenvJson;
    };
    hmMarkdownDoc = {
      role = "HM options CommonMark";
      path = docs.hmOptionsDoc.optionsCommonMark;
    };
    devenvMarkdownDoc = {
      role = "devenv options CommonMark";
      path = docs.devenvOptionsDoc.optionsCommonMark;
    };
    jsonDocs = [hmJsonDoc devenvJsonDoc];
    markdownDocs = [hmMarkdownDoc devenvMarkdownDoc];
    # One call of a shell guard helper (defined in the build below) per
    # rendering: `<helper> <role> <path> <args…>`.
    guard = helper: renderings: args:
      lib.concatMapStringsSep "\n" (doc: "${helper} ${lib.escapeShellArgs ([doc.role "${doc.path}"] ++ args)}")
      renderings;
    # `guard` for each name in a list, with `extra` appended after the name.
    guardEach = helper: renderings: extra: names:
      lib.concatMapStringsSep "\n" (name: guard helper renderings ([name] ++ extra)) names;
  in {
    options-doc-ai-parity = pkgs.runCommand "options-doc-ai-parity" {} ''
      diff="${lib.getExe' pkgs.diffutils "diff"}"
      grep="${lib.getExe pkgs.gnugrep}"
      jq="${lib.getExe pkgs.jq}"
      sort="${lib.getExe' pkgs.coreutils "sort"}"

      # Guard helpers. Each takes the rendering's role, its path and the option
      # or text it guards, and on failure names all three on stderr. A tool
      # error (exit status above 1) is reported as such, never read as a
      # verdict, so an unreadable rendering cannot pass an absence guard.
      fail() {
        echo "options-doc-ai-parity: $*" >&2
        exit 1
      }
      jq_holds() {
        local rc=0
        "$jq" --exit-status --arg name "$3" "$4" "$2" >/dev/null || rc=$?
        [ "$rc" -le 1 ] || fail "jq exited $rc on '$3' in the $1 ($2)"
        return "$rc"
      }
      text_found() {
        local rc=0
        "$grep" -Fq -- "$3" "$2" || rc=$?
        [ "$rc" -le 1 ] || fail "grep exited $rc on '$3' in the $1 ($2)"
        return "$rc"
      }
      require_key() {
        jq_holds "$1" "$2" "$3" 'has($name)' ||
          fail "required option '$3' is missing from the $1 ($2)"
      }
      forbid_key() {
        jq_holds "$1" "$2" "$3" 'has($name) | not' ||
          fail "retired or internal option '$3' is present in the $1 ($2)"
      }
      require_description() {
        jq_holds "$1" "$2" "$3" ".[\$name].description | $4" ||
          fail "description of '$3' in the $1 fails '$4' ($2)"
      }
      require_text() {
        text_found "$1" "$2" "$3" ||
          fail "required text '$3' is missing from the $1 ($2)"
      }
      forbid_text() {
        if text_found "$1" "$2" "$3"; then
          fail "internal name '$3' is present in the $1 ($2)"
        fi
      }

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

      # Every runtime owns one native settings file under an ordinary
      # namespace; Kimchi owns a second, harness settings file. The former flat
      # names are a deliberate clean cut rather than a compatibility alias.
      ${guardEach "require_key" jsonDocs [] (map (runtime: "ai.${runtime}.native.settings") runtimes)}
      ${guardEach "forbid_key" jsonDocs [] (map (runtime: "ai.${runtime}.nativeSettings") runtimes)}
      ${guard "require_key" jsonDocs ["ai.kimchi.native.harnessSettings"]}
      ${guard "forbid_key" jsonDocs ["ai.kimchi.harnessSettings"]}

      # Semantic-agent `.instructions` fields and Semble's nested program feature
      # remain valid. Only the normalized root and per-runtime guidance surface
      # was retired.
      ${guardEach "forbid_key" jsonDocs [] (["ai.instructions"] ++ map (runtime: "ai.${runtime}.instructions") runtimes)}

      # Internal channels must remain absent from both consumer-facing
      # references even though they are declared symmetrically. That covers the
      # integration inputs AND `_ownPlans`, which exists so module evaluation
      # can read what a reconciler's store plan will assert — it is a check
      # seam, never an ownership surface a consumer may declare.
      ${guardEach "forbid_text" (jsonDocs ++ markdownDocs) [] ["_integration_writable_roots" "_ownPlans"]}

      # Devenv-only service APIs still belong in the consumer reference. This
      # positive control prevents an omitted transform prefix from silently
      # filtering the complete Beads module tree.
      ${guard "require_key" [devenvJsonDoc] ["services.beads.enable"]}
      ${guard "require_text" [devenvMarkdownDoc] ["services\\.beads\\.enable"]}

      # Exercise every runtime namespace in the CommonMark renderings too; JSON
      # parity alone would let a broken markdown generator remain dormant after
      # the doc-site removal. nixos-render-docs escapes dots in option headings.
      ${guardEach "require_text" markdownDocs [] (map (app: "ai\\.${app}\\.enable") runtimes)}

      ${guardEach "require_description" jsonDocs [''contains("Codex")''] sharedDescriptionsThatMustDiscussCodex}
      ${guardEach "require_description" jsonDocs [''contains("Kimchi")''] sharedDescriptionsThatMustDiscussKimchi}
      ${guardEach "require_description" jsonDocs [''contains("Home Manager") and contains("warn")''] copilotDescriptionsThatMustDiscussHmWarning}

      # The successful check output is also the requested machine-readable parity
      # report: one complete, sorted contract shared by both backends.
      cp hm-ai-options "$out"
    '';
  };
}
