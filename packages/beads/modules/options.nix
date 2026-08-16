{lib}: {
  options.services.beads = {
    enable = lib.mkEnableOption "the contained Beads repository lifecycle";

    issuePrefix = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "project";
      description = ''
        Required issue prefix for the isolated ledger. It is fixed when the
        lifecycle first owns a repository and cannot be changed in place.
      '';
    };

    ledgerUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "ssh://git@example.invalid/project-ledger.git";
      description = ''
        Required, unmodified Git remote URL that owns refs/dolt/data. Do not
        put credentials in this value: Nix configuration is copied to the
        store. Runtime Git and SSH credential discovery remains user-owned.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      defaultText = lib.literalExpression "pkgs.ai.devTools.beads";
      description = "Pinned Beads package; its passthru.dolt is the paired Dolt runtime.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3307;
      description = "Loopback port for the repository-owned shared Dolt daemon.";
    };

    publishIntervalSeconds = lib.mkOption {
      type = lib.types.ints.between 30 3600;
      default = 300;
      description = "Bounded interval between raw-Dolt publication attempts.";
    };
  };
}
