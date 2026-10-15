# `ai.proxy` configuration on both backends: root selection assertions, and
# the Home Manager-only CLIProxyAPI services with the registry that announces
# them. The options are declared by `rootOption` (./default.nix), which
# sharedOptions.nix registers as the shared `proxy` surface; per-runtime
# selection lives in mkBackendTransform.nix.
#
# Services are Home Manager only, an approved config-parity exception: a
# devenv shell has no user-service lifecycle, and it inherits the user-global
# registry anyway. devenv rejects `instances` with an assertion rather than
# dropping them. Linux only for now: there is no launchd writer in this repo,
# so Darwin warns and still writes the registry, for a proxy run by hand.
#
# ── Why the config is rendered at service start ───────────────────────
# CLIProxyAPI reads client keys only as plaintext in its YAML and rewrites
# that file itself, so it cannot be a store path. The start script renders a
# private, writable copy in the unit's state directory on every start, reading
# a `file` or `helper` client key there; only its path is in the store. JSON
# is YAML, so `jq` writes it. The key reaches `jq` through its environment,
# never argv (/proc/<pid>/cmdline is world-readable).
#
# Upstream secrets take the same route. `settings` is typed from the pinned
# CLIProxyAPI (packages/cliproxyapi/lib/extracted.nix), and a credential
# there takes the repo's secret type in place: the store holds a `file` or
# `helper` reference, and one jq program puts each value at its JSON path.
#
# Account fields are reconciled into the login's auth file with the general
# reconciler (lib/own), one ledger per account under the unit's state
# directory, so a field Nix stops declaring is retracted and a field it never
# wrote is left alone.
{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  proxyLib = import ./. {inherit lib;};
  cliproxyapi = import ../../../packages/cliproxyapi/lib/extracted.nix {inherit lib;};
  credentials = import ../../credentials.nix {inherit lib;};
  own = import ../../own {inherit lib;};
  cfg = config.ai.proxy;
  inherit (cfg) instances;
  isHomeManager = lib.hasAttrByPath ["xdg" "configFile"] options;
  hasSystemd = lib.hasAttrByPath ["systemd" "user" "services"] options;
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
  names = builtins.attrNames instances;
  path = name: ["ai" "proxy" "instances" name];

  # CLIProxyAPI's shipped example keys switch it into a safe mode that turns
  # its API endpoints off (the safe-mode check in example_api_keys.go).
  exampleKeys = ["your-api-key-1" "your-api-key-2" "your-api-key-3"];
  # A blank host binds every interface (config_load.go), as do the wildcards.
  wildcardHosts = ["" "0.0.0.0" "::" "[::]"];

  # The auth dir the start script resolves, null for its default. Only an
  # absolute path, `~` or `~/…` is accepted (instanceAssertions): those
  # resolve here exactly as CLIProxyAPI's ResolveAuthDir
  # (internal/util/util.go) does, and the resolved path is what the config
  # names. CPA maps "" to its own default and cleans a relative path against
  # its working directory, neither of which the reconcile can address.
  authDirOf = inst: inst.settings.oauth.auth-dir or null;

  instanceAssertions = name: inst: let
    option = lib.showOption (path name);
    authDir = authDirOf inst;
  in
    [
      {
        assertion = builtins.match "[A-Za-z0-9][A-Za-z0-9_-]*" name != null;
        message = "${option}: the instance name becomes a systemd unit and a state directory, so use letters, digits, `_` and `-`, starting with a letter or digit.";
      }
      {
        assertion = !(builtins.elem inst.host wildcardHosts);
        message = "${option}.host = \"${inst.host}\" binds every interface. Bind one address: 127.0.0.1 (the default), or the address a sandbox reaches the host on.";
      }
      {
        assertion = builtins.elem inst.host wildcardHosts || builtins.match proxyLib.patterns.url (proxyLib.originFor inst) != null;
        message = "${option}.host must be a host name or an IP address, without brackets or a port.";
      }
      {
        assertion = inst.clientKey != null;
        message = "${option}.clientKey must be set: it is the key harnesses present, and the registry hands it to them.";
      }
      {
        assertion = authDir == null || authDir == "~" || lib.hasPrefix "~/" authDir || lib.hasPrefix "/" authDir;
        message = "${option}.settings.oauth.auth-dir = \"${toString authDir}\" must be an absolute path, `~` or `~/…`, or unset for the unit's state directory. CLIProxyAPI's ResolveAuthDir would read \"\" as its own default and a relative path against its working directory, where the account reconcile cannot follow.";
      }
    ]
    ++ lib.optionals (inst.clientKey != null) (
      [
        {
          assertion = !(builtins.elem (inst.clientKey.plain or null) exampleKeys);
          message = "${option}.clientKey.plain is one of CLIProxyAPI's example keys, which switch its API endpoints off. Choose another key.";
        }
      ]
      ++ proxyLib.toAssertions (proxyLib.keyProblem "${option}.clientKey" inst.clientKey)
    )
    # mkSecretAssignment double-quotes a file or helper path into the start
    # script, so it is held to the client key's path pattern.
    ++ lib.concatMap (entry: proxyLib.toAssertions (proxyLib.keyProblem (lib.showOption entry.option) entry.secret)) (secretsOf name inst)
    ++ map (account: {
      assertion = builtins.match accountPattern account != null;
      message = "${lib.showOption (path name ++ ["accounts" account])}: an account is named after its auth file without `.json`, such as `claude-1a2b3c4d-you@example.com`, so use letters, digits and `._@+-`, not starting with `.`.";
    }) (builtins.attrNames inst.accounts);

  # Each account's fields as `cliproxyapi.renderAccount` splits them: `value`
  # for the store plan, `secrets` read at start into the run-time plan. An
  # account with neither owns nothing, so a past run's fields in its file
  # are retired like a removed one's.
  accountsOf = inst: lib.filterAttrs (_: account: account.value != {} || account.secrets != []) (lib.mapAttrs (_: cliproxyapi.renderAccount) inst.accounts);

  # Every `file` or `helper` secret of an instance, settings first, with its
  # option path, its JSON path in the config or the account's fields, the
  # account it belongs to (accounts only) and the variable the start script
  # reads it into.
  secretsOf = name: inst:
    lib.imap0 (index: entry: entry // {var = "AI_PROXY_SECRET_${toString index}";})
    (map (entry: entry // {option = path name ++ ["settings"] ++ map toString entry.path;}) (cliproxyapi.render inst.settings).secrets
      ++ lib.concatLists (lib.mapAttrsToList (account: rendered:
        map (entry:
          entry
          // {
            inherit account;
            option = path name ++ ["accounts" account] ++ map toString entry.path;
          })
        rendered.secrets) (accountsOf inst)));

  # An auth file's name without `.json`; it also names the account's ledger.
  accountPattern = "[A-Za-z0-9_@+-][A-Za-z0-9._@+-]*";

  portOwners = lib.groupBy (name: toString instances.${name}.port) names;
  sharedPorts = lib.filterAttrs (_: owners: builtins.length owners > 1) portOwners;

  startScript = name: inst: let
    rendered = cliproxyapi.render inst.settings;
    allSecrets = secretsOf name inst;
    secrets = builtins.filter (entry: !(entry ? account)) allSecrets;
    accountSecrets = builtins.filter (entry: entry ? account) allSecrets;
    # `VAR="$VAR" …`: a secret reaches jq through its environment, not argv.
    envFor = lib.concatMapStrings (entry: "${entry.var}=\"\$${entry.var}\" ");
    # Where the account reconcile looks, and what the config names, as one
    # value (authDirOf).
    authDir = authDirOf inst;
    authDirLine =
      if authDir == null
      then ''auth_dir="$state/auth"''
      else if authDir == "~" || lib.hasPrefix "~/" authDir
      then ''auth_dir="$HOME"${lib.escapeShellArg (lib.removePrefix "~" authDir)}''
      else "auth_dir=${lib.escapeShellArg authDir}";
    # The fields each account sets in the store; its secrets are set into
    # the run-time plan.
    accountFields = lib.mapAttrs (_: account: account.value) (accountsOf inst);
    declared = builtins.attrNames accountFields;
    # One target per declared account, in `declared` order, its ledger named
    # after it. The last target is the retirement of an account a past run
    # declared, its name filled in at run time.
    placeholder = "@AI_PROXY_ACCOUNT@";
    accountTarget = account: fields: {
      codec = "json";
      ledger = "accounts/${account}.json";
      path = "${account}.json";
      units = lib.optionalAttrs (fields != {}) {text = builtins.toJSON fields;};
    };
    accountPlan = own.mkPlan {
      inherit pkgs;
      targets = map (account: accountTarget account accountFields.${account}) declared ++ [(accountTarget placeholder {})];
    };
  in
    import ../../strict-shell-application.nix pkgs {
      name = "ai-proxy-${name}";
      text = ''
        umask 077
        state="''${STATE_DIRECTORY:?ai-proxy-${name} runs as a systemd unit with StateDirectory set}"
        ${credentials.mkSecretAssignment pkgs "client_key" inst.clientKey}
        ${lib.concatMapStringsSep "\n" (entry: credentials.mkSecretAssignment pkgs entry.var entry.secret) allSecrets}
        ${authDirLine}
        ${pkgs.coreutils}/bin/mkdir -p "$auth_dir"
        ${envFor secrets}CPA_CLIENT_KEY="$client_key" ${lib.getExe pkgs.jq} \
          --arg authDir "$auth_dir" \
          --argjson secrets ${lib.escapeShellArg (builtins.toJSON (map (entry: {inherit (entry) path var;}) secrets))} \
          --from-file ${cliproxyapi.configFilter} \
          ${pkgs.writeText "ai-proxy-${name}-settings.json" (builtins.toJSON rendered.value)} \
          >"$state/config.yaml.new"
        ${pkgs.coreutils}/bin/mv -f "$state/config.yaml.new" "$state/config.yaml"

        # Before exec, so CLIProxyAPI loads the declared fields. Only accounts
        # whose auth file exists take part: a login not made yet is skipped,
        # and a retired account's ledger goes with its file.
        declare -A declared=(${lib.concatMapStringsSep " " (account: "[${lib.escapeShellArg account}]=1") declared})
        present=()
        retired=()
        for account in "''${!declared[@]}"; do
          if [ -e "$auth_dir/$account.json" ]; then
            present+=("$account")
          fi
        done
        for ledger in "$state"/own/accounts/*.json; do
          [ -e "$ledger" ] || continue
          account="''${ledger##*/}"
          account="''${account%.json}"
          if [ -n "''${declared[$account]:-}" ]; then
            continue
          fi
          if [ -e "$auth_dir/$account.json" ]; then
            retired+=("$account")
          else
            ${pkgs.coreutils}/bin/rm -f "$ledger"
          fi
        done
        if [ "''${#present[@]}" -gt 0 ] || [ "''${#retired[@]}" -gt 0 ]; then
          # Account names hold no `/`, so it separates the two lists. Each
          # account secret is set into its target's fields here, so the
          # store plan holds only its file or helper path, in this script.
          ${envFor accountSecrets}${lib.getExe pkgs.jq} --null-input \
            --argjson declared ${lib.escapeShellArg (builtins.toJSON declared)} \
            --argjson secrets ${lib.escapeShellArg (builtins.toJSON (map (entry: {inherit (entry) account path var;}) accountSecrets))} \
            --arg placeholder ${placeholder} \
            --slurpfile plan ${accountPlan.file} \
            '($ARGS.positional | index("/")) as $split
             | $plan[0]
             | .targets as $targets
             | .targets = [range($declared | length) | select($declared[.] | IN($ARGS.positional[:$split][])) | $targets[.]]
               + [$ARGS.positional[$split + 1:][] as $account | $targets[-1] | .ledger |= sub($placeholder; $account) | .path |= sub($placeholder; $account)]
             | reduce $secrets[] as $secret (.;
                 .targets |= map(if .ledger == "accounts/\($secret.account).json"
                   then .units.text = ((.units.text // "{}") | fromjson | setpath($secret.path; env[$secret.var]) | tojson)
                   else . end))' \
            --args "''${present[@]}" / "''${retired[@]}" >"$state/accounts-plan.json"
          ${own.mkCommand {
          inherit pkgs;
          planFile = "$state/accounts-plan.json";
          python = pkgs.python3;
          root = "$auth_dir";
          state = "$state/own";
        } ""}
        fi
        exec ${lib.getExe inst.package} --config "$state/config.yaml"
      '';
    };

  unitFor = name: inst: {
    Unit = {
      Description = "CLIProxyAPI AI proxy instance ${name}";
      # A start that fails every time (a missing secret file, an auth file
      # the reconcile cannot parse) ends `failed` after three tries a minute,
      # where systemd's default 5 in 10s never trips at RestartSec = 5.
      StartLimitBurst = 3;
      StartLimitIntervalSec = 60;
    };
    Service = {
      ExecStart = lib.getExe (startScript name inst);
      Restart = "on-failure";
      RestartSec = 5;
      # %S/ai-proxy/<name> ($XDG_STATE_HOME): the rendered config and, unless
      # `settings.oauth.auth-dir` says otherwise, the OAuth logins.
      StateDirectory = "ai-proxy/${name}";
      StateDirectoryMode = "0700";
      SyslogIdentifier = "ai-proxy-${name}";
    };
    Install.WantedBy = ["default.target"];
  };
in {
  config = lib.mkMerge [
    (lib.optionalAttrs (options ? assertions) {
      assertions =
        proxyLib.assertionsFor ["ai" "proxy"] cfg
        ++ [
          {
            assertion = isHomeManager || instances == {};
            message = "ai.proxy.instances (${lib.concatStringsSep ", " names}) is Home Manager only: devenv runs no user services. Define the instance in Home Manager, whose registry a devenv shell reads, or select a proxy you run yourself with ai.proxy.url and ai.proxy.key in devenv.local.nix.";
          }
          {
            assertion = sharedPorts == {};
            message = "ai.proxy.instances share a port: ${lib.concatStringsSep "; " (lib.mapAttrsToList (port: owners: "${port} (${lib.concatStringsSep ", " owners})") sharedPorts)}. Give each instance its own port.";
          }
        ]
        ++ lib.concatLists (lib.mapAttrsToList instanceAssertions instances);
    })
    (lib.optionalAttrs isHomeManager {
      xdg.configFile.${proxyLib.registryPath} = lib.mkIf (instances != {}) {
        text = builtins.toJSON (lib.mapAttrs (_: proxyLib.registryEntry) instances);
      };
      warnings = lib.optional (instances != {} && !isLinux) "ai.proxy.instances (${lib.concatStringsSep ", " names}) defines CLIProxyAPI services, but only Linux systemd user units are implemented; nothing starts them on ${pkgs.stdenv.hostPlatform.system}. The registry still lists them, so run each proxy yourself on its host, port and client key.";
    })
    (lib.optionalAttrs (isHomeManager && hasSystemd) {
      systemd.user.services = lib.mkIf isLinux (lib.mapAttrs' (name: inst: lib.nameValuePair "ai-proxy-${name}" (unitFor name inst)) instances);
    })
  ];
}
