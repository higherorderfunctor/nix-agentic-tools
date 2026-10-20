# Daemon schema, launch-time environment and backend lowering share one source.
{lib}: let
  redact = import ../../../lib/redact {inherit lib;};
  strictShellApplication = import ../../../lib/strict-shell-application.nix;
  claimAssertions = claims:
    lib.concatLists (lib.mapAttrsToList (group: keys:
      lib.mapAttrsToList (key: owners: {
        assertion = builtins.length owners <= 1;
        message = "ai.claims.${group}.${key}: claimed by ${lib.concatStringsSep " and " (lib.sort lib.lessThan owners)}";
      })
      keys)
    claims);
  defaulted = type: default: lib.mkOption {inherit type default;};
  identifier = "[A-Za-z_][A-Za-z0-9_]*";
  # A config file rendered at start: JSON text whose secrets are whole-string
  # `{$NAME}` placeholders (lib/extracted/render.nix), so the text is safe in
  # the store; `secrets` maps each NAME to the reference that fills it.
  fileEntry = lib.types.submodule {
    options = {
      content = lib.mkOption {type = lib.types.str;};
      secrets = defaulted (lib.types.attrsOf redact.types.redacted) {};
      variable = lib.mkOption {type = lib.types.strMatching identifier;};
    };
  };
  serviceEntry = lib.types.submodule {
    options = {
      command = lib.mkOption {type = lib.types.nonEmptyListOf lib.types.str;};
      enable = defaulted lib.types.bool true;
      environment = defaulted redact.types.environment {};
      files = defaulted (lib.types.attrsOf fileEntry) {};
      ports = defaulted (lib.types.attrsOf lib.types.port) {};
      restart = defaulted (lib.types.enum ["always" "never" "on-failure"]) "on-failure";
      restartOnChange = defaulted (lib.types.listOf (lib.types.strMatching "/.*")) [];
    };
  };
  # Files whose content change restarts the service: the declared paths plus
  # every `redact.file` the environment and the rendered files read.
  triggers = entry: let
    values = builtins.attrValues entry.environment ++ lib.concatMap (file: builtins.attrValues file.secrets) (builtins.attrValues entry.files);
  in
    lib.sort lib.lessThan (lib.unique (entry.restartOnChange ++ lib.concatMap redact.filePaths values));
  # Every NAME of a `{$NAME}` string in a JSON value. Bracket expressions,
  # since libstdc++'s ERE rejects an escaped brace.
  placeholderPattern = "[{][$](" + identifier + ")[}]";
  placeholders = value:
    if builtins.isString value
    then let
      match = builtins.match placeholderPattern value;
    in
      lib.optionals (match != null) match
    else if builtins.isAttrs value
    then lib.concatMap placeholders (builtins.attrValues value)
    else if builtins.isList value
    then lib.concatMap placeholders value
    else [];
  # Content and secrets are both known at evaluation, so a mismatch fails the
  # build instead of a start: a placeholder with no secret would reach the
  # daemon as literal text, and a secret with no placeholder is never read.
  checkFile = option: file: let
    used = lib.unique (placeholders (builtins.fromJSON file.content));
    missing = lib.subtractLists (builtins.attrNames file.secrets) used;
    unused = lib.subtractLists used (builtins.attrNames file.secrets);
  in
    if missing != []
    then throw "${option}: placeholders with no secret: ${lib.concatStringsSep ", " missing}"
    else if unused != []
    then throw "${option}: secrets with no placeholder: ${lib.concatStringsSep ", " unused}"
    else file;
  # Each file is written to `<key>.json` in a 0700 per-service runtime
  # directory: a 0600 temporary copy with every placeholder replaced by its
  # secret as a JSON string, then a same-directory rename, so the daemon never
  # reads a partial file. A secret goes into a launcher-named variable that is
  # never exported; only jq's own environment carries it, since argv is
  # world-readable in /proc. The daemon gets the path in `variable`.
  renderFiles = pkgs: name: files: let
    coreutils = "${pkgs.coreutils}/bin";
    slots = lib.imap0 (index: slot: slot // {variable = "_ai_secret_${toString index}";}) (lib.concatLists (lib.mapAttrsToList (key: file:
      lib.mapAttrsToList (secret: value: {inherit key secret value;}) (checkFile "ai.services.${name}.files.${key}" file).secrets)
    files));
    slotNames = lib.concatMapStringsSep " " (slot: slot.variable) slots;
    render = key: file: let
      own = lib.filter (slot: slot.key == key) slots;
      tokens = builtins.listToAttrs (map (slot: lib.nameValuePair ("{" + "$" + slot.secret + "}") slot.variable) own);
      target = ''"$_ai_dir"/${lib.escapeShellArg "${key}.json"}'';
    in
      if builtins.match "[A-Za-z0-9][A-Za-z0-9_.-]*" key == null
      then throw "ai.services.${name}.files.${key}: file keys must match [A-Za-z0-9][A-Za-z0-9_.-]*"
      else ''
        _ai_file="$(${coreutils}/mktemp "$_ai_dir/.${key}.XXXXXX")"
        # jq's filter and token names are literal text.
        # shellcheck disable=SC2016
        ${lib.concatMapStrings (slot: slot.variable + "=\"$" + slot.variable + "\" ") own}${pkgs.jq}/bin/jq --argjson tokens ${lib.escapeShellArg (builtins.toJSON tokens)} \
          'walk(. as $value | if type == "string" and ($tokens | has($value)) then $ENV[$tokens[$value]] else . end)' \
          ${pkgs.writeText "ai-service-${name}-${key}.json" file.content} > "$_ai_file"
        ${coreutils}/mv -f -- "$_ai_file" ${target}
        export ${file.variable}=${target}
      '';
  in
    lib.optionalString (files != {}) ''
      # Inherited exported slots must lose both their value and export flag
      # before any reader runs; resolved slots are private to this launcher.
      ${lib.optionalString (slots != []) "unset ${slotNames}"}
      {
      ${lib.concatMapStringsSep "\n" (slot:
        redact.assign {
          inherit pkgs;
          inherit (slot) value variable;
          option = "ai.services.${name}.files.${slot.key}.secrets.${slot.secret}";
        })
      slots}
      :
      }
      if [ -n "''${XDG_RUNTIME_DIR:-}" ]; then
        _ai_dir="$XDG_RUNTIME_DIR"/${lib.escapeShellArg "ai-service-${name}"}
      else
        _ai_dir="''${TMPDIR:-/tmp}/ai-service-$(${coreutils}/id -u)-"${lib.escapeShellArg name}
      fi
      umask 077
      if ! ${coreutils}/mkdir -m 0700 -- "$_ai_dir" 2>/dev/null; then
        if [ -L "$_ai_dir" ] || [ ! -d "$_ai_dir" ] || [ ! -O "$_ai_dir" ]; then
          printf '%s\n' ${lib.escapeShellArg "ai.services.${name}.files: runtime directory must be an owned directory, not a symlink:"} "$_ai_dir" >&2
          exit 1
        fi
      fi
      ${coreutils}/chmod 0700 "$_ai_dir"
      ${lib.concatStrings (lib.mapAttrsToList render files)}
      ${lib.optionalString (slots != []) "unset ${slotNames}"}'';
  mkLauncher = {
    pkgs,
    name,
    entry,
  }: let
    inherit (entry) files;
    variables = builtins.attrNames entry.environment ++ lib.mapAttrsToList (_: file: file.variable) files;
    clashes = lib.unique (lib.filter (variable: lib.count (other: other == variable) variables > 1) variables);
    reserved =
      map (variable: "ai.services.${name}.environment.${variable}") (lib.filter (lib.hasPrefix "_ai_") (builtins.attrNames entry.environment))
      ++ lib.mapAttrsToList (key: _: "ai.services.${name}.files.${key}.variable") (lib.filterAttrs (_: file: lib.hasPrefix "_ai_" file.variable) files);
  in
    if reserved != []
    then throw "${lib.concatStringsSep ", " reserved}: the _ai_ variable prefix is reserved for the service launcher"
    else if clashes != []
    then throw "ai.services.${name}: a file variable repeats another file's or an environment variable: ${lib.concatStringsSep ", " clashes}"
    else
      strictShellApplication pkgs {
        name = "ai-service-${name}";
        text = ''
          # Generated literal assignments: dollar signs and quotes are data.
          # shellcheck disable=SC2016,SC2089,SC2090
          {
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (variable: value:
            redact.assign {
              inherit pkgs value variable;
              export = true;
              option = "ai.services.${name}.environment.${variable}";
            })
          entry.environment)}
          :
          }
          ${renderFiles pkgs name files}
          # shellcheck disable=SC2016
          exec ${lib.escapeShellArgs entry.command}
        '';
      };
  enabled = lib.filterAttrs (_: entry: entry.enable);
  launch = pkgs: name: entry: "${mkLauncher {inherit pkgs name entry;}}/bin/ai-service-${name}";
  readsSecrets = entry:
    lib.any (value: value != null && !builtins.isString value) (builtins.attrValues entry.environment)
    || lib.any (file: file.secrets != {}) (builtins.attrValues entry.files);
  hmUnits = pkgs: services: {
    providerUnits,
    userServices,
  }: let
    # Each provider unit defined here, with the targets it is wanted by. A unit
    # declared but not defined in this configuration contributes no target.
    defined = lib.concatMap (unit: let
      name = lib.removeSuffix ".service" unit;
    in
      lib.optional (builtins.hasAttr name userServices) {
        inherit unit;
        targets = lib.sort lib.lessThan (lib.unique (userServices.${name}.Install.WantedBy or []));
      })
    providerUnits;
    # A target wants each provider independently, so a reader wanted by the
    # union of two providers' targets could start with one of them and never
    # wait for the other. Readers follow one target set or evaluation stops.
    targetSets = lib.unique (map (provider: provider.targets) defined);
    wantedBy =
      if builtins.length targetSets > 1
      then throw "ai.activationOrder.secretProviders: provider units ${lib.concatMapStringsSep ", " (provider: "${provider.unit} (${lib.concatStringsSep " " provider.targets})") defined} start under different targets, so a secret-reading service cannot start with all of them; give their units the same WantedBy"
      else if targetSets == [] || builtins.head targetSets == []
      then ["default.target"]
      else builtins.head targetSets;
  in
    lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (lib.mapAttrs (name: entry: let
      secretReader = readsSecrets entry;
    in
      if secretReader && builtins.elem "${name}.service" providerUnits
      then throw "ai.services.${name}: a secret-reading service cannot be its own provider unit"
      else {
        Install.WantedBy =
          if secretReader
          then wantedBy
          else ["default.target"];
        Service = {
          ExecStart = launch pkgs name entry;
          Restart =
            if entry.restart == "never"
            then "no"
            else entry.restart;
          RestartSec = 5;
        };
        # Secret readers start after provider units under the providers' targets.
        Unit = {
          After = ["network.target"] ++ lib.optionals secretReader providerUnits;
          Description = "${name} (ai.services)";
        };
      }) (enabled services));
  hmWarnings = pkgs: services: lib.optionals (!pkgs.stdenv.hostPlatform.isLinux) (map (name: "ai.services.${name}: Home Manager writes services as systemd user units, which this platform lacks; the service is not written") (builtins.attrNames (enabled services)));
  devenvProcesses = pkgs: services:
    lib.mapAttrs (
      name: entry:
        {
          exec = launch pkgs name entry;
          restart.on =
            if entry.restart == "on-failure"
            then "on_failure"
            else entry.restart;
        }
        // lib.optionalAttrs (triggers entry != []) {watch.paths = triggers entry;}
    ) (enabled services);
  # Home Manager has no live file watch: each activation hashes the readable
  # trigger files and restarts a running unit whose hash changed since the
  # recorded one. The first record restarts nothing, `try-restart` leaves a
  # stopped unit stopped, and a missing or unreadable file is skipped so an
  # secret that is not decrypted yet cannot abort activation.
  rotationCheck = pkgs: name: paths: ''
    hash_file="$state_dir/${name}.sha256"
    new_hash="$(
      for path in ${lib.escapeShellArgs paths}; do
        if [ -f "$path" ] && [ -r "$path" ]; then
          ${pkgs.coreutils}/bin/sha256sum -- "$path"
        fi
      done | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d ' ' -f1
    )"
    old_hash=""
    if [ -r "$hash_file" ]; then
      old_hash="$(${pkgs.coreutils}/bin/cat -- "$hash_file")"
    fi
    if [ -n "$old_hash" ] && [ "$old_hash" != "$new_hash" ]; then
      ${pkgs.systemd}/bin/systemctl --user try-restart ${lib.escapeShellArg name}
    fi
    printf '%s' "$new_hash" > "$hash_file"
  '';
  hmRestart = pkgs: services: let
    watched = lib.filterAttrs (_: paths: paths != []) (lib.mapAttrs (_: triggers) (enabled services));
  in
    lib.optionalAttrs (pkgs.stdenv.hostPlatform.isLinux && watched != {}) {
      services-restart-on-change = {
        after = ["files" "secrets"];
        before = ["shell"];
        command = ''
          case "$(${pkgs.systemd}/bin/systemctl --user is-system-running 2>/dev/null || :)" in
            running | degraded) ;;
            *) exit 0 ;;
          esac
          state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/nix-agentic-tools/services"
          ${pkgs.coreutils}/bin/mkdir -p "$state_dir"
          ${pkgs.coreutils}/bin/chmod 700 "$state_dir"
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (rotationCheck pkgs) watched)}
        '';
      };
    };
in {
  inherit claimAssertions devenvProcesses hmRestart hmUnits hmWarnings mkLauncher serviceEntry triggers;
}
