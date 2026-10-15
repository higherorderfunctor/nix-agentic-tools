# A runtime factory's staged generated files (`ai.<runtime>._generatedFiles`)
# over the layers, through a synthetic runtime record and every repository
# module: formatted text reaches `ai.files2` as its tree file, value leaves
# merge with a consumer's, a consumer's layer-1 content wins, a disabled
# runtime reads and forwards nothing, an old-path duplicate is refused (a staged
# path whose layer-1 entry is switched off included), a switched-off context file is warned about by its layer-1 option, and the
# plan-aware harness readers return the engine's `ro`/`rw` entries.
{
  harness,
  lib,
  pkgs,
  ...
}: let
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
      files2 = {
        "override.txt".content.text = "consumer";
        "settings.json".content.value.owned = document.owned;
      };
    };
  };
  inherit (enabled.config.ai) files2;
  source = "${enabled.config.ai.probe._generatedTree}/doc.md";
  # A disabled runtime never reads its staged entries: neither its layer 1
  # (`ai.probe.files2`) nor its tree (the adapter gate) forces this throw.
  disabled = evaluate {
    ai.probe._generatedFiles."lazy.txt".content.text = throw "a disabled runtime read its staged entries";
  };
  clash = evaluate {
    ai.probe = {
      enable = true;
      files = {
        "clash.txt".content.text = "old";
        "doc.md".content.text = "old";
      };
      files2 = {
        "clash.txt".content.text = "new";
        "doc.md".enable = false;
      };
    };
  };
  switchedOff = evaluate {
    ai = {
      context.text = "context";
      probe = {
        enable = true;
        files2."doc.md".enable = false;
      };
    };
  };
  refused = path: lib.any (assertion: !assertion.assertion && lib.hasInfix path assertion.message) clash.config.assertions;
  delivered = harness.deliveredFiles enabled.config;
  failures =
    lib.optional (files2."doc.md".content.source != source || files2."doc.md".method != "ro") "formatted source reaches ai.files2"
    ++ lib.optional (files2."settings.json".content.value != document) "value leaves merge"
    ++ lib.optional (files2."override.txt".content._choice != "text" || files2."override.txt".content.text != "consumer") "consumer layer-1 content wins"
    ++ lib.optional (disabled.config.ai.probe.files2 != {} || disabled.config.ai.probe._generatedTree != null || disabled.config.ai.files2 != {} || disabled.config.ai.files2Owners != {}) "disabled runtime forwards nothing"
    ++ lib.optional (!refused "clash.txt") "old-path duplicate refused"
    ++ lib.optional (!refused "doc.md") "old path shadowing a switched-off staged path refused"
    ++ lib.optional (!lib.any (lib.hasInfix ''ai.probe.files2."doc.md".enable = false'') switchedOff.config.warnings) "warnings read layer-1 enable"
    ++ lib.optional (map (target: target.path) (harness.ownPlan "probe" "files2-apply" enabled).targets != ["doc.md" "settings.json"]) "ownPlan"
    ++ lib.optional ((harness.ownedDocument "probe" "settings.json" enabled).value != document) "ownedDocument"
    ++ lib.optional ((delivered."doc.md".source or null) != source || (delivered."settings.json".method or null) != "rw") "deliveredFiles"
    ++ lib.optional (harness.markdownInput enabled "doc.md" != {text = markdown;}) "markdownInput";
in {
  checks.ai-module-generated-files = assert lib.assertMsg (failures == []) "generated files: ${lib.concatStringsSep ", " failures}";
    pkgs.runCommandLocal "ai-module-generated-files" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      # Prettier rewrites the `*` bullet to `-`, so the tree file is formatted.
      ${pkgs.gnugrep}/bin/grep -qx -- '- item' ${source}
      printf 'PASS: staged files reach ai.files2 formatted, mergeable, overridable and gated\n' > "$out"
    '';
}
