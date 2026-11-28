# A runtime factory's staged generated files (`ai.<runtime>._generatedFiles`)
# over the layers, through a synthetic runtime record and every repository
# module: formatted text reaches `ai.files` as its tree file, value leaves
# merge with a consumer's, a consumer's layer-1 content wins, a disabled
# runtime reads and forwards nothing, the plan-aware harness readers return
# the engine's `ro`/`rw` entries, and
# `ai.formatter` and `ai.guards` reach the runtime's tree.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) checkRows;
  ai = import ../../../lib/ai {inherit lib;};
  markdown = "* item\n";
  document = {
    owned = 3;
    sibling = 2;
  };
  record = ai.app.mkRuntime {
    inherit pkgs;
    name = "probe";
    contentTargets = _: {context = "doc.md";};
    contextFilename = "doc.md";
    defaults.package = pkgs.hello;
    surfaceSupport.context.backends = ["devenv" "hm"];
    config = _: {
      ai.probe._generatedFiles = {
        "doc.md" = {
          content.text = markdown;
          format = "markdown";
          method = "ro";
        };
        "override.txt".content.text = "generated";
        "settings.json" = {
          content.value = {
            owned = 1;
            inherit (document) sibling;
          };
          format = "json";
          method = "rw";
        };
      };
    };
  };
  evaluate = config: harness.evalHmModules [(ai.app.hmTransform record) {inherit config;}];
  enabled = evaluate {
    ai.probe = {
      enable = true;
      files = {
        "override.txt".content.text = "consumer";
        "settings.json".content.value.owned = document.owned;
      };
    };
  };
  inherit (enabled.config.ai) files;
  source = "${enabled.config.ai.probe._generatedTree}/doc.md";
  # A disabled runtime never reads its staged entries: neither its layer 1
  # (`ai.probe.files`) nor its tree forces this throw.
  disabled = evaluate {
    ai.probe._generatedFiles."lazy.txt".content.text = throw "a disabled runtime read its staged entries";
  };
  # Prettier switched off in `ai.formatter`: doc.md has no formatter, which
  # fails the tree, and the guards that follow prettier default off.
  unformatted = evaluate {
    ai = {
      formatter.programs.prettier.enable = lib.mkForce false;
      probe.enable = true;
    };
  };
  # A staged table whose body row has more cells than its header: the default
  # tableCells guard fails the tree, and switching it off lets the tree build.
  guarded = guards:
    (evaluate {
      ai = {
        inherit guards;
        probe = {
          enable = true;
          _generatedFiles."table.md" = {
            content.text = "| A | B |\n| - | - |\n| x | `|| true` y |\n";
            format = "markdown";
            method = "ro";
          };
        };
      };
    }).config.ai.probe._generatedTree;
  buildLog = tree: "${pkgs.testers.testBuildFailure tree}/testBuildFailure.log";
  delivered = harness.deliveredFiles enabled.config;
  rows = checkRows "generated files" {
    "consumer text wins over staged text for the same target" = files."override.txt".content._choice == "text" && files."override.txt".content.text == "consumer";
    "deliveredFiles sees the formatted source" = (delivered."doc.md".source or null) == source;
    "disabled runtime never reads staged content or forwards files and claims" = disabled.config.ai.probe.files == {} && disabled.config.ai.probe._generatedTree == null && disabled.config.ai.files == {} && disabled.config.ai.claims.path == {};
    "formatted document reaches the public pool as a read-only copy" = files."doc.md".method == "ro";
    "ownPlan includes copy and merge targets but not the native link" = map (target: target.path) (harness.ownPlan "probe" "files-apply" enabled).targets == ["doc.md" "settings.json"];
    "ownedDocument reads the merged value from the plan" = (harness.ownedDocument "probe" "settings.json" enabled).value == document;
    "prettier-dependent guards default off only with prettier disabled" = lib.all (guard: enabled.config.ai.guards.${guard} && !unformatted.config.ai.guards.${guard}) ["splitCodeSpans" "tableCells"];
  };
in {
  checks.ai-module-generated-files = assert rows;
    pkgs.runCommandLocal "ai-module-generated-files" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      # Prettier rewrites the `*` bullet to `-`, so the tree file is formatted.
      ${pkgs.gnugrep}/bin/grep -qx -- '- item' ${source}
      ${pkgs.gnugrep}/bin/grep -qF 'no formatter for path: doc.md' ${buildLog unformatted.config.ai.probe._generatedTree}
      ${pkgs.gnugrep}/bin/grep -qF 'Generated-file guard tableCells failed.' ${buildLog (guarded {})}
      [[ -f ${guarded {tableCells = false;}}/table.md ]]
      printf 'PASS: staged files reach ai.files formatted, mergeable, overridable and gated\n' > "$out"
    '';
}
