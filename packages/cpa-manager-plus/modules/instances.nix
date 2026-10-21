# `ai.cpa-manager-plus.instances.<name>`: CPA Manager Plus daemons, the same on
# both backends apart from the default state root. config.json is rendered at
# each start and `CPA_MANAGER_CONFIG` points at it; the key-carrying variables
# stay redact references in the service environment. `upstream` names the
# CLIProxyAPI instance it manages. `settings.config.adminKeyFile` is applied at
# every start, not only the first.
backend: {
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (import ../lib/default.nix {inherit lib;}) cpa-manager-plus;
  instances = import ../../ai-module/lib/instances.nix {inherit lib;};
  select = top: name: instance:
    instances.select {
      instances = top.ai.cliproxyapi.instances;
      name = instance.upstream;
      option = "ai.cpa-manager-plus.instances.${name}.upstream";
      owner = "cliproxyapi";
    };
  set = value: value != null && lib.trim value != "";
  # The database as Manager Plus 1.14.7 resolves it (config.go
  # LoadWithOptions): a variable's relative path against the working
  # directory, `stateDir`, and a config.json one against the rendered file's.
  database = instance: let
    inherit (instance.settings) config environment;
    fromConfig = path:
      if lib.hasPrefix "/" path
      then lib.escapeShellArg path
      else ''"''${CPA_MANAGER_CONFIG%/*}"/${lib.escapeShellArg path}'';
  in
    if set environment.USAGE_DB_PATH
    then lib.escapeShellArg (lib.trim environment.USAGE_DB_PATH)
    else if set environment.USAGE_DATA_DIR
    then lib.escapeShellArg "${lib.trim environment.USAGE_DATA_DIR}/usage.sqlite"
    else if set config.dbPath
    then fromConfig (lib.trim config.dbPath)
    else lib.escapeShellArg "${config.dataDir}/usage.sqlite";
  adminKeyVariables = ["CPA_MANAGER_ADMIN_KEY" "CPA_MANAGER_ADMIN_KEY_FILE"];
in {
  imports = [
    (instances.module {
      arguments = "";
      inherit backend;
      defaultPort = 18317;
      # Native defaults would bind every interface and keep the data next to
      # the config, in the launcher's runtime directory.
      derived = {
        config,
        instance,
        name,
      }: let
        selected =
          if instance.upstream == null
          then {}
          else select config name instance;
        key = lib.attrByPath ["management" "secret-key"] null config.ai.cliproxyapi.instances.${instance.upstream}.settings;
      in {
        config =
          {
            dataDir = instance.stateDir;
            httpAddr = "127.0.0.1:${toString instance.port}";
          }
          // lib.optionalAttrs (selected ? url) {cpaUpstreamUrl = lib.mkDefault selected.url;};
        environment = lib.optionalAttrs (selected ? url && key != null) {CPA_MANAGEMENT_KEY = lib.mkDefault key;};
      };
      extraOptions.upstream = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "main";
        description = ''
          The `ai.cliproxyapi.instances` entry this instance manages. It
          defaults `settings.config.cpaUpstreamUrl` to that instance's
          loopback origin and `settings.environment.CPA_MANAGEMENT_KEY` to its
          `settings.management.secret-key` reference.
        '';
      };
      owner = "cpa-manager-plus";
      packagePath = "generic.cpa-manager-plus";
      packageText = import ../../../lib/ai/nat-package-text.nix {inherit lib;} "generic.cpa-manager-plus";
      # Manager Plus reads its admin key only while no credential is stored
      # (bootstrap ensureAdminCredential), so a stored one is reset to the
      # file's on every start. reset-admin-key refuses a missing or empty
      # database; that is a first start, whose bootstrap seeds the credential
      # from the same file and would generate one from an unreadable or blank
      # file instead.
      preStart = instance: let
        db = database instance;
        key = lib.escapeShellArg instance.settings.config.adminKeyFile;
      in
        lib.optionalString (instance.settings.config.adminKeyFile != null) ''
          if [ -s ${db} ]; then
            ${lib.getExe instance.package} reset-admin-key --db-path ${db} --admin-key-file ${key}
          elif ! ${pkgs.gnugrep}/bin/grep -q '[^[:space:]]' ${key}; then
            printf '%s\n' ${lib.escapeShellArg "settings.config.adminKeyFile: ${instance.settings.config.adminKeyFile} is unreadable or blank"} >&2
            exit 1
          fi
        '';
      inherit (cpa-manager-plus) render settingsType;
      # A relative path fails the assertion below instead of the trigger type.
      restartOnChange = instance: lib.optional (lib.hasPrefix "/" (toString instance.settings.config.adminKeyFile)) instance.settings.config.adminKeyFile;
      tool = "CPA Manager Plus";
      variable = "CPA_MANAGER_CONFIG";
    })
  ];

  config.assertions = lib.concatLists (lib.mapAttrsToList (name: instance:
    lib.optional (instance.enable && instance.upstream != null) (let
      selected = select config name instance;
    in {
      assertion = selected ? url;
      message = selected.problem or "";
    })
    # Either variable shadows adminKeyFile (config.go readSecret) and is read
    # on the first start only; the plain key would reach reset-admin-key only
    # through argv or a copy on disk.
    ++ map (variable: {
      assertion = !instance.enable || instance.settings.environment.${variable} == null;
      message = "ai.cpa-manager-plus.instances.${name}.settings.environment.${variable}: set settings.config.adminKeyFile instead; Manager Plus reads ${variable} only on its first start, while the instance applies adminKeyFile on every start.";
    })
    adminKeyVariables
    # A relative path resolves inside the launcher's runtime directory and
    # cannot be a restart trigger.
    ++ lib.optional (instance.settings.config.adminKeyFile != null) {
      assertion = lib.hasPrefix "/" instance.settings.config.adminKeyFile;
      message = "ai.cpa-manager-plus.instances.${name}.settings.config.adminKeyFile: must be an absolute path, not `${instance.settings.config.adminKeyFile}`.";
    })
  config.ai.cpa-manager-plus.instances);
}
