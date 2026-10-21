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
  # One sha256 over each trigger path and its bytes; `files` is shell words.
  # sha256sum names a file it cannot read and fails, so a missing trigger
  # never hashes as empty.
  digest = pkgs: files: "${pkgs.coreutils}/bin/sha256sum -- ${files} | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d ' ' -f1";
  # Where a Home Manager launcher records what its start read. The user
  # manager sets XDG_RUNTIME_DIR for every unit; the reconcile entry exports
  # it before reading.
  stampFile = name: ''"$XDG_RUNTIME_DIR"/${lib.escapeShellArg "ai-service-${name}.stamp"}'';
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
    stamp ? false,
  }: let
    inherit (entry) files;
    coreutils = "${pkgs.coreutils}/bin";
    stamped = stamp && triggers entry != [];
    # Each stamp block ends in a newline and is spliced at the start of the
    # line it precedes, so an unstamped launcher's text is unchanged.
    hashBlock = lib.optionalString stamped ''
      # Hashed before any secret is read: a file replaced after this
      # leaves the stamp older than the daemon, never newer.
      _ai_digest="$(${digest pkgs (lib.escapeShellArgs (triggers entry))})"
    '';
    stampBlock = lib.optionalString stamped ''
      # What this invocation read, for Home Manager's post-reload check.
      _ai_stamp=${stampFile name}
      _ai_temporary="$(${coreutils}/mktemp "$_ai_stamp.XXXXXX")"
      printf '%s %s\n' "$_ai_digest" "$INVOCATION_ID" > "$_ai_temporary"
      ${coreutils}/mv -f -- "$_ai_temporary" "$_ai_stamp"
    '';
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
          ${hashBlock}# Generated literal assignments: dollar signs and quotes are data.
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
          ${stampBlock}# shellcheck disable=SC2016
          exec ${lib.escapeShellArgs entry.command}
        '';
      };
  enabled = lib.filterAttrs (_: entry: entry.enable);
  launch = stamp: pkgs: name: entry: "${mkLauncher {inherit pkgs name entry stamp;}}/bin/ai-service-${name}";
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
    # A reader pulls every provider in through Wants=, so under the union of
    # two providers' targets it would start one provider early, under the
    # other's target. Readers follow one target set or evaluation stops.
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
          ExecStart = launch true pkgs name entry;
          Restart =
            if entry.restart == "never"
            then "no"
            else entry.restart;
          RestartSec = 5;
        };
        # Wants=, not Requires= or After= alone: DESIGN.md, Services.
        Unit =
          {
            After = ["network.target"] ++ lib.optionals secretReader providerUnits;
            Description = "${name} (ai.services)";
          }
          // lib.optionalAttrs secretReader {Wants = providerUnits;};
      }) (enabled services));
  hmWarnings = pkgs: services: lib.optionals (!pkgs.stdenv.hostPlatform.isLinux) (map (name: "ai.services.${name}: Home Manager writes services as systemd user units, which this platform lacks; the service is not written") (builtins.attrNames (enabled services)));
  devenvProcesses = pkgs: services:
    lib.mapAttrs (
      name: entry:
        {
          exec = launch false pkgs name entry;
          restart.on =
            if entry.restart == "on-failure"
            then "on_failure"
            else entry.restart;
        }
        // lib.optionalAttrs (triggers entry != []) {watch.paths = triggers entry;}
    ) (enabled services);
  # Restarts readers whose stamp is stale after sd-switch; DESIGN.md, Services.
  hmReconcile = pkgs: services: {
    providerUnits,
    systemctlPath,
    # Seconds each pass waits for running starts to stamp; DESIGN.md, Services.
    stampTimeout ? 90,
  }: let
    coreutils = "${pkgs.coreutils}/bin";
    watched = lib.filterAttrs (_: paths: paths != []) (lib.mapAttrs (_: triggers) (enabled services));
    names = builtins.attrNames watched;
    observer = index: name: ''
      observe_${toString index}() { observe ${lib.escapeShellArg "${name}.service"} ${stampFile name} ${lib.escapeShellArgs watched.${name}}; }
    '';
  in
    lib.optionalAttrs (pkgs.stdenv.hostPlatform.isLinux && watched != {}) {
      services-reconcile = {
        after = ["files" "secrets"];
        afterNodes = {
          devenv = [];
          hm = ["reloadSystemd"];
        };
        before = ["shell"];
        command = ''
          ctl=${lib.escapeShellArg systemctlPath}
          uid="$(${coreutils}/id -u)"
          export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$uid}"
          prop() { "$ctl" --user show --property="$2" --value "$1"; }
          # Sets `fresh` once the unit's running invocation has stamped: yes or
          # no for its stamp against the trigger files now, inactive, or
          # unstamped when it stays active past the pass's `deadline` without
          # a stamp from its running invocation. Each unit is read at least once.
          observe() {
            local unit=$1 stamp=$2 state sub invocation current recorded started
            shift 2
            while :; do
              state="$(prop "$unit" ActiveState)"
              sub="$(prop "$unit" SubState)"
              if [ "$state" = failed ] || [ "$sub" = auto-restart ]; then
                printf 'ai.services: %s is %s (%s)\n' "$unit" "$state" "$sub" >&2
                false
              fi
              if [ "$state" != active ]; then
                fresh=inactive
                return
              fi
              invocation="$(prop "$unit" InvocationID)"
              recorded="" started=""
              [ ! -f "$stamp" ] || read -r recorded started < "$stamp"
              if [ "$started" = "$invocation" ]; then
                current="$(${digest pkgs ''"$@"''})"
                fresh=no
                [ "$recorded" != "$current" ] || fresh=yes
                return
              fi
              if [ "$SECONDS" -ge "$deadline" ]; then
                fresh=unstamped
                return
              fi
              ${coreutils}/sleep 0.2
            done
          }
          ${lib.concatStrings (lib.imap0 observer names)}
          reconcile() {
            local provider load result index
            for provider in ${lib.escapeShellArgs providerUnits}; do
              load="$(prop "$provider" LoadState)"
              if [ "$load" != not-found ]; then
                result="$(prop "$provider" Result)"
                if [ "$result" != success ]; then
                  printf 'ai.services: secret provider %s last ran with Result=%s\n' "$provider" "$result" >&2
                  false
                fi
              fi
            done
            units=(${lib.escapeShellArgs (map (name: "${name}.service") names)})
            stale=() restart=()
            deadline=$((SECONDS + ${toString stampTimeout}))
            for index in "''${!units[@]}"; do
              "observe_$index"
              if [ "$fresh" = no ] || [ "$fresh" = unstamped ]; then
                stale+=("$index")
                restart+=("''${units[index]}")
              fi
            done
            if [ "''${#stale[@]}" -gt 0 ]; then
              "$ctl" --user try-restart "''${restart[@]}"
              deadline=$((SECONDS + ${toString stampTimeout}))
              for index in "''${stale[@]}"; do
                "observe_$index"
                if [ "$fresh" != yes ]; then
                  printf 'ai.services: %s did not restart onto its current trigger files (%s)\n' "''${units[index]}" "$fresh" >&2
                  false
                fi
              done
            fi
          }
          skip() { printf 'ai.services: the user manager is not running (%s); skipping service reconciliation\n' "$1"; }
          status="$("$ctl" --user is-system-running 2>&1 || :)"
          case "$status" in
            running | degraded) reconcile ;;
            starting | stopping) skip "$status" ;;
            *)
              manager="$("$ctl" --system show --property=ActiveState --value "user@$uid.service" 2>&1)" || manager="unknown: $manager"
              if [ "$manager" = active ]; then
                printf 'ai.services: user@%s.service is active, but its manager reports: %s\n' "$uid" "$status" >&2
                false
              fi
              skip "user@$uid.service: $manager"
              ;;
          esac
        '';
      };
    };
in {
  inherit claimAssertions devenvProcesses hmReconcile hmUnits hmWarnings mkLauncher serviceEntry triggers;
}
