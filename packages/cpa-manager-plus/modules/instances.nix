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
  given = value: value != null && value != "";
  # Go's unicode.IsSpace (go1.25.3 src/unicode/graphic.go, tables.go
  # _White_Space), which strings.TrimSpace strips.
  spaces = builtins.fromJSON ''["\t", "\n", "\u000b", "\f", "\r", " ", "\u0085", "\u00a0", "\u1680", "\u2000", "\u2001", "\u2002", "\u2003", "\u2004", "\u2005", "\u2006", "\u2007", "\u2008", "\u2009", "\u200a", "\u2028", "\u2029", "\u202f", "\u205f", "\u3000"]'';
  # An absolute path that filepath.Join and strings.TrimSpace leave as
  # written, so Manager Plus opens exactly it.
  clean = path:
    builtins.isString path
    && lib.hasPrefix "/" path
    && lib.all (segment: !lib.elem segment ["" "." ".."]) (lib.tail (lib.splitString "/" path))
    && !lib.any (space: lib.hasSuffix space path) spaces;
  # What places the database, by option. The run script unsets the variables
  # an instance does not declare, so these are all of it.
  databaseInputs = instance: {
    "settings.config.dataDir" = instance.settings.config.dataDir;
    "settings.config.dbPath" = instance.settings.config.dbPath;
    "settings.environment.USAGE_DATA_DIR" = instance.settings.environment.USAGE_DATA_DIR;
    "settings.environment.USAGE_DB_PATH" = instance.settings.environment.USAGE_DB_PATH;
  };
  # The database Manager Plus 1.14.7 opens (config.go LoadWithOptions
  # 115-128): USAGE_DB_PATH, then USAGE_DATA_DIR/usage.sqlite, then dbPath,
  # then dataDir/usage.sqlite. With every input clean, as asserted below, it
  # joins and trims nothing.
  database = instance: let
    inherit (instance.settings) config environment;
  in
    if given environment.USAGE_DB_PATH
    then environment.USAGE_DB_PATH
    else if given environment.USAGE_DATA_DIR
    then "${environment.USAGE_DATA_DIR}/usage.sqlite"
    else if given config.dbPath
    then config.dbPath
    else "${toString config.dataDir}/usage.sqlite";
  adminKeyVariables = ["CPA_MANAGER_ADMIN_KEY" "CPA_MANAGER_ADMIN_KEY_FILE"];
  databaseVariables = ["USAGE_DATA_DIR" "USAGE_DB_PATH"];
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
      # file instead. Without --db-path the reset loads the same config and
      # environment the server does (its resolveDBPath); `database` only
      # tells a first start apart. Inherited admin-key variables would seed a
      # first start in place of the file (config.go readSecret), and
      # inherited database variables would move the database away from
      # `database`, so the run script drops every one the instance does not
      # declare; declared admin-key ones are refused below.
      preStart = instance: let
        key = lib.escapeShellArg instance.settings.config.adminKeyFile;
        # Bootstrap trims with strings.TrimSpace: drop the non-ASCII spaces
        # byte-wise, so C's [:space:] covers the rest.
        blankSpaces = toString (map (space: "-e ${lib.escapeShellArg "s/${space}//g"}") (lib.filter (space: builtins.stringLength space > 1) spaces));
      in
        lib.optionalString (instance.settings.config.adminKeyFile != null) ''
          unset ${toString (adminKeyVariables ++ lib.filter (variable: !given instance.settings.environment.${variable}) databaseVariables)}
          if [ -s ${lib.escapeShellArg (database instance)} ]; then
            ${lib.getExe instance.package} reset-admin-key --admin-key-file ${key}
          elif ! stripped="$(LC_ALL=C ${pkgs.gnused}/bin/sed ${blankSpaces} -- ${key} 2>/dev/null)" || ! LC_ALL=C ${pkgs.gnugrep}/bin/grep -q '[^[:space:]]' <<<"$stripped"; then
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
    ++ lib.optionals (instance.settings.config.adminKeyFile != null) ([
        {
          # Bootstrap trims the path; the trigger, the probe and the reset do not.
          assertion = clean instance.settings.config.adminKeyFile;
          message = "ai.cpa-manager-plus.instances.${name}.settings.config.adminKeyFile: must be an absolute path with no empty, `.` or `..` segment and no trailing whitespace, not `${instance.settings.config.adminKeyFile}`.";
        }
      ]
      # The first-start probe tests `database`, which is the database
      # Manager Plus opens only when every input it reads is clean; dataDir,
      # `stateDir` by default, is always read when the others are unset.
      ++ lib.mapAttrsToList (option: value: {
        assertion = clean value || option != "settings.config.dataDir" && !given value;
        message = "ai.cpa-manager-plus.instances.${name}.${option}: with settings.config.adminKeyFile set, must be an absolute path with no empty, `.` or `..` segment and no trailing whitespace, which Manager Plus opens as written; not `${toString value}`.";
      }) (databaseInputs instance)))
  config.ai.cpa-manager-plus.instances);
}
