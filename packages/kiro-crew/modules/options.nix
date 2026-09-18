# The kiro-crew option tree, declared ONCE and consumed by both backends.
#
# Shared rather than written twice because this repo's stated contract is that
# anything configurable in Home Manager is configurable in devenv and vice
# versa, and gaps between the two are bugs. Declaring here makes parity a
# property of the code rather than something a reviewer has to notice.
#
# NOT under `ai.*`. That namespace is the shared AI-surface fanout — the same
# instructions, MCP servers, agents and hooks translated per ecosystem — and
# `checks/modules/options-doc.nix` holds it to exact HM/devenv option-tree
# parity for that reason. Kiro Crew is an application with its own gateway and
# its own config shapes, most of which have no lossless mapping onto that
# fanout, so it lives in `services.kirocrew.*` where the tree is its own.
{
  lib,
  pkgs,
}: {
  enable = lib.mkEnableOption "Kiro Crew, the local agent gateway and dashboard";

  package = lib.mkOption {
    type = lib.types.package;
    default = pkgs.ai.kiro-crew;
    defaultText = lib.literalExpression "pkgs.ai.kiro-crew";
    description = ''
      The Kiro Crew package to install.

      The default already carries the packaged embedding model, so the gateway
      does not fetch it at first start. Override with
      `pkgs.ai.kiro-crew.override { embedModel = null; }` to take the download
      instead and drop ~610 MB from the closure.
    '';
  };

  dataDir = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "/var/lib/kirocrew";
    description = ''
      Where Kiro Crew keeps its data, exported as `KIROCREW_HOME`.

      `null` leaves upstream's default of `~/.kiro/crew` and does NOT set the
      variable. That distinction is upstream's, not ours: several behaviors
      key off whether the home is the default one, including the recovery
      breadcrumb written beside `~/.kiro`, so setting the variable to its own
      default value is not a no-op.

      When set, the same value roots the PPTX engine seed below, so the two
      cannot disagree about where the engine lives.
    '';
  };

  pptxEngine = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Seed the packaged Spec-Driven Presentation Maker engine into Kiro
        Crew's per-user tree, so the PPTX Maker app does not download it.

        Defaults true because the packaged engine is the point: without the
        seed the app fetches ~3 MB from GitHub at first provision and verifies
        it against a digest it also fetched the expectation for, whereas the
        seeded tree was verified at build time against upstream's own pinned
        constants.

        This only removes the ENGINE download. The engine's Python
        dependencies are still resolved by `uv` on first provision.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.ai.kiro-crew-pptx-engine;
      defaultText = lib.literalExpression "pkgs.ai.kiro-crew-pptx-engine";
      description = "The engine tree to seed.";
    };
  };
}
