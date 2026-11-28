# Generated option-documentation parity check.
#
# The old mdbook/NuschtOS site was deliberately removed, but
# lib/options-doc.nix remains the canonical evaluator for consumer-facing HM
# and devenv option references. Build both renderings so documentation-only
# regressions are caught even when module behavior and backend parity agree.
# The guards name the rendering and the option, text, or type map that failed.
#
# Shared runtime and pool APIs have exact option-tree parity. Non-AI owners'
# helper namespaces follow their native lifecycle backend; docs still expose
# them, and presence guards below keep those explicit exclusions honest.
# Claude's launch-effort unpin, Codex's daemon selection and session trust, and
# Kiro's permission rules and trusted MCP tools (read only from ~/.kiro)
# remain backend-specific leaves.
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
    nonCodexRuntimes = lib.remove "codex" runtimes;
    # The type-map diff is the only devenv presence/absence guard for the shared
    # paths pinned below; widening either list can remove that coverage.
    localOwners = {
      devenv = ["beads" "git" "git-branchless"];
      hm = ["glab" "mcp-services"];
    };
    backendOnly = {
      devenv = [
        # Project settings need a launcher fallback before trust; HM user settings
        # already apply independently of project trust.
        "ai.claude.untrustedProjectAdditionalDirectories"
        "ai.codex.trustProjectForSession"
      ];
      hm = ["ai.claude.native.installMethod" "ai.claude.native.unpinLaunchEffort" "ai.codex.pinDaemonToPackage" "ai.kiro.cli.trustedMcpTools" "ai.kiro.permissions"];
    };
    comparable = backend: let
      # An exact ai.<owner> option is part of that owner's namespace too.
      excluded = map (owner: "ai.${owner}") localOwners.${backend} ++ backendOnly.${backend};
    in ''
      with_entries(select(.key | startswith("ai.")))
      | with_entries(select(.key as $key | all(${builtins.toJSON excluded}[]; . as $root | $key != $root and ($key | startswith($root + ".") | not))))
    '';
    expectedCodexRoots = pkgs.writeText "expected-codex-option-roots" (
      lib.concatStringsSep "\n" [
        "ai.codex.activation"
        "ai.codex.agents"
        "ai.codex.agentsDir"
        "ai.codex.checks"
        "ai.codex.configDir"
        "ai.codex.context"
        "ai.codex.enable"
        "ai.codex.environmentVariables"
        "ai.codex.execpolicyRules"
        "ai.codex.files"
        "ai.codex.hooks"
        "ai.codex.jail"
        "ai.codex.mcpServers"
        "ai.codex.normalized"
        "ai.codex.package"
        "ai.codex.pinDaemonToPackage"
        "ai.codex.projectDocMaxBytes"
        "ai.codex.proxy"
        "ai.codex.rules"
        "ai.codex.rulesDir"
        "ai.codex.services"
        "ai.codex.shell"
        "ai.codex.skills"
        "ai.codex.skillsDir"
      ]
      + "\n"
    );
    # Each row pins the runtime names or scope warning that must remain in the
    # published description even if the underlying option still works.
    descriptions = {
      # Shared pools can support a runtime or explicitly exclude it.
      "ai.agents" = ["Codex" "Kimchi"];
      "ai.context" = ["Codex" "Kimchi"];
      "ai.environmentVariables" = ["Codex"];
      "ai.hooks" = ["Codex" "Kimchi"];
      "ai.jail" = ["Codex" "Kimchi"];
      "ai.mcpServers" = ["Codex" "Kimchi"];
      "ai.rules" = ["Codex" "Kimchi"];
      "ai.rulesDir" = ["Codex"];
      # Codex needed a launcher wrapper to receive the shell. Naming just the
      # settings-driven runtimes would hide that support from readers.
      "ai.shell" = ["Codex"];
      "ai.skills" = ["Codex" "Kimchi"];
      "ai.skillsDir" = ["Codex" "Kimchi"];

      # Home Manager warns about non-empty project-only Copilot inputs.
      "ai.copilot.github.context" = ["Home Manager" "warn"];
      "ai.copilot.github.rules" = ["Home Manager" "warn"];
    };
    renderings =
      lib.mapAttrs (_: {
        role,
        options,
      }: {
        json = {
          role = "${role} options JSON";
          path = "${options.optionsJSON}/share/doc/nixos/options.json";
        };
        markdown = {
          role = "${role} options CommonMark";
          path = options.optionsCommonMark;
        };
      }) {
        devenv = {
          options = docs.devenvOptionsDoc;
          role = "devenv";
        };
        hm = {
          options = docs.hmOptionsDoc;
          role = "HM";
        };
      };
    inherit (renderings) devenv hm;
    backends = lib.attrNames renderings;
    jsonDocs = map (backend: renderings.${backend}.json) backends;
    markdownDocs = map (backend: renderings.${backend}.markdown) backends;
    # One call of a shell guard helper (defined in the build below) per
    # rendering: `<helper> <role> <path> <args…>`.
    guard = helper: docsToCheck: args:
      lib.concatMapStringsSep "\n" (doc: "${helper} ${lib.escapeShellArgs ([doc.role "${doc.path}"] ++ args)}")
      docsToCheck;
    guardEach = helper: docsToCheck: names:
      lib.concatMapStringsSep "\n" (name: guard helper docsToCheck [name]) names;
  in {
    options-doc-ai-parity = pkgs.runCommand "options-doc-ai-parity" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
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
      forbid_surface() {
        jq_holds "$1" "$2" "$3" 'any(keys[]; . == $name or startswith($name + ".")) | not' ||
          fail "retired surface '$3' is present in the $1 ($2)"
      }
      require_description() {
        jq_holds "$1" "$2" "$3" ".[\$name].description | (. // \"\") | contains($4)" ||
          fail "description of '$3' in the $1 is missing $4 ($2)"
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

      # The normalized type map is keyed by flattened option names, so its diff
      # catches missing leaves as well as options that accept a different value
      # shape in one backend. Defaults and descriptions may intentionally differ
      # with lifecycle/scope, so they are documented and behavior-tested rather
      # than mechanically equated here.
      ${lib.concatMapStringsSep "\n" (backend: ''
          "$jq" -S '${comparable backend} | map_values({type: .type})' "${renderings.${backend}.json.path}" > ${backend}-ai-types.json
        '')
        backends}
      "$diff" -u hm-ai-types.json devenv-ai-types.json || fail "shared HM and devenv option names or types differ"

      # Excluded owners can disappear from their native reference without
      # changing parity. Pin one leaf per layer there. A leak in the other
      # reference is already an unmatched key in the type diff above.
      ${lib.concatMapStringsSep "\n" (backend:
        guardEach "require_key" [renderings.${backend}.json] (lib.concatMap
          (owner: ["ai.${owner}.activation.<name>.command" "ai.${owner}.files.<name>.enable" "ai.${owner}.services.<name>.command"])
          localOwners.${backend}))
      backends}

      # The type diff alone accepts both backends losing a Codex surface.
      # Pin the published HM roots; the type diff checks the shared ones in devenv.
      # The leaf guards below already pin native and settings. Match those roots
      # exactly so a new root with a similar name still fails the diff.
      "$jq" -r '
        keys[]
        | select(startswith("ai.codex."))
        | split(".")[0:3]
        | join(".")
        | select(. != "ai.codex.native" and . != "ai.codex.settings")
      ' "${hm.json.path}" | "$sort" -u > actual-codex-option-roots
      "$diff" -u "${expectedCodexRoots}" actual-codex-option-roots || fail "published HM Codex option roots changed"

      # Inference lives under settings; option roots alone cannot prove its
      # selection fields remain documented on both consumers and the root.
      # Pin these and the retired paths in HM; the type-map diff covers devenv.
      ${guardEach "require_key" [hm.json] (lib.concatMap
        (scope: map (field: "ai.${scope}settings.inference.${field}") ["clientKey" "instance" "key" "url"])
        ["" "claude." "codex."])}

      # Pin the published paths independently of the declarations, so losing a
      # settings option from both backends still fails. Add a row when a
      # runtime gains a settings file. Kiro's namespace is CLI-specific; Kimchi
      # owns a second, harness settings file. Copilot's github.com arm reads no
      # settings file, so it declares none. The former flat names are not
      # compatibility aliases.
      ${guardEach "require_key" [hm.json] [
        "ai.claude.native.settings"
        "ai.codex.native.settings"
        "ai.kimchi.native.harnessSettings"
        "ai.kimchi.native.settings"
        "ai.kiro.cli.native.settings"
      ]}
      # The pinned HM roots already exclude both retired Codex surfaces.
      ${guardEach "forbid_surface" [hm.json] ((map (runtime: "ai.${runtime}.nativeSettings") nonCodexRuntimes) ++ ["ai.kimchi.harnessSettings"])}

      # Semantic-agent `.instructions` fields and Semble's nested program feature
      # remain valid. Only the normalized root and per-runtime guidance surface
      # was retired.
      ${guardEach "forbid_surface" [hm.json] (["ai.instructions"] ++ map (runtime: "ai.${runtime}.instructions") nonCodexRuntimes)}

      # Integration inputs stay absent from the JSON used to render CommonMark.
      ${guard "forbid_text" jsonDocs ["_integration_writable_roots"]}

      # Devenv-only service APIs still belong in the consumer reference. This
      # positive control prevents an omitted transform prefix from silently
      # filtering the complete Beads module tree. The heading comes from the
      # published JSON key, so it also covers missing JSON entries.
      ${guard "require_text" [devenv.markdown] ["services\\.beads\\.enable"]}

      # Exercise every runtime namespace in the CommonMark renderings too; JSON
      # parity alone would let a broken markdown generator remain dormant after
      # the doc-site removal. nixos-render-docs escapes dots in option headings.
      ${guardEach "require_text" markdownDocs (map (app: "ai\\.${app}\\.enable") runtimes)}

      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: terms:
        lib.concatMapStringsSep "\n" (term: guard "require_description" jsonDocs [name (builtins.toJSON term)]) terms)
      descriptions)}

      # The successful check output is also the requested machine-readable parity
      # report: one complete, sorted contract shared by both backends.
      "$jq" -r 'keys[]' hm-ai-types.json > "$out"
    '';
  };
}
