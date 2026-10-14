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
{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  proxyLib = import ./. {inherit lib;};
  credentials = import ../../credentials.nix {inherit lib;};
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

  instanceAssertions = name: inst: let
    option = lib.showOption (path name);
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
    ]
    ++ lib.optionals (inst.clientKey != null) (
      [
        {
          assertion = !(builtins.elem (inst.clientKey.plain or null) exampleKeys);
          message = "${option}.clientKey.plain is one of CLIProxyAPI's example keys, which switch its API endpoints off. Choose another key.";
        }
      ]
      ++ proxyLib.toAssertions (proxyLib.keyProblem "${option}.clientKey" inst.clientKey)
    );

  portOwners = lib.groupBy (name: toString instances.${name}.port) names;
  sharedPorts = lib.filterAttrs (_: owners: builtins.length owners > 1) portOwners;

  startScript = name: inst:
    import ../../strict-shell-application.nix pkgs {
      name = "ai-proxy-${name}";
      text = ''
        umask 077
        state="''${STATE_DIRECTORY:?ai-proxy-${name} runs as a systemd unit with StateDirectory set}"
        ${credentials.mkSecretAssignment pkgs "client_key" inst.clientKey}
        ${pkgs.coreutils}/bin/mkdir -p "$state/auth"
        AI_PROXY_CLIENT_KEY="$client_key" ${lib.getExe pkgs.jq} \
          --arg authDir "$state/auth" \
          '.access["api-keys"] = ((.access["api-keys"] // []) + [env.AI_PROXY_CLIENT_KEY])
           | .oauth["auth-dir"] //= $authDir' \
          ${pkgs.writeText "ai-proxy-${name}-settings.json" (builtins.toJSON inst.settings)} \
          >"$state/config.yaml.new"
        ${pkgs.coreutils}/bin/mv -f "$state/config.yaml.new" "$state/config.yaml"
        exec ${lib.getExe inst.package} --config "$state/config.yaml"
      '';
    };

  unitFor = name: inst: {
    Unit.Description = "CLIProxyAPI AI proxy instance ${name}";
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
