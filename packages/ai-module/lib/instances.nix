# Named instances of one tool, each lowered to one `ai.<owner>.services` entry
# (and so its service and port claims), with its typed settings rendered to a
# config file at start through `serviceEntry.files`. CLIProxyAPI and CPA
# Manager Plus share it; an owner supplies its settings type and render, the
# settings it derives from an instance, and the instance's command.
{lib}: let
  strictShellApplication = import ../../../lib/strict-shell-application.nix;
  # Where an instance keeps its writable state by default: the user's XDG
  # state directory on Home Manager, the project's devenv state on devenv, so
  # a per-repository instance never shares logins with another repository.
  stateRoots = {
    devenv = {
      text = "\${config.devenv.state}";
      value = config: config.devenv.state;
    };
    hm = {
      text = "\${config.xdg.stateHome}";
      value = config: config.xdg.stateHome;
    };
  };
in {
  # `http://127.0.0.1:<port>` of the enabled instance `name`, or why `option`
  # cannot select it. Selection uses loopback, matching owner bind defaults.
  select = {
    instances,
    name,
    option,
    owner,
  }: let
    instance = instances.${name} or null;
  in
    if instance == null
    then {problem = "${option} names `${name}`, which is not an `ai.${owner}.instances` entry.";}
    else if !instance.enable
    then {problem = "${option} names `ai.${owner}.instances.${name}`, which is disabled.";}
    else {url = "http://127.0.0.1:${toString instance.port}";};

  # The owner module for one backend (`hm` or `devenv`). `derived` gives the
  # settings an instance fixes (its port, its state paths), which merge with
  # the consumer's and conflict on a different value; `render` turns settings
  # into `{ content; secrets; environment? }`; `variable` carries the rendered
  # file's path; `arguments` are the shell words after the executable (a
  # string, or a function of the instance when a word depends on its options)
  # and `directories` the state subdirectories created with `stateDir`.
  # `preStart` is shell the run script runs in `stateDir`, with `variable`
  # exported, before it execs the executable; `restartOnChange` adds the
  # service's restart triggers.
  # `packagePath` is the default package's path under `ai.internal.packages`
  # and `packageText` its documentation.
  module = {
    arguments,
    backend,
    defaultPort,
    derived,
    directories ? _: [],
    extraOptions ? {},
    owner,
    packagePath,
    packageText,
    preStart ? _: "",
    render,
    restartOnChange ? _: [],
    settingsType,
    tool,
    variable,
  }: {
    config,
    pkgs,
    ...
  }: let
    top = config;
    instances = config.ai.${owner}.instances;
    argumentsOf = instance:
      if lib.isFunction arguments
      then arguments instance
      else arguments;
  in {
    imports = [
      (import ./runtime.nix {
        enabled = true;
        name = owner;
      })
    ];

    options.ai.${owner}.instances = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({
        config,
        name,
        ...
      }: {
        options =
          {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether to run this ${tool} instance. A disabled instance still claims its service name and port.";
            };
            package = lib.mkOption {
              type = lib.types.package;
              default = lib.getAttrFromPath (lib.splitString "." packagePath) top.ai.internal.packages;
              defaultText = packageText;
              description = "The ${tool} package this instance runs.";
            };
            port = lib.mkOption {
              type = lib.types.port;
              default = defaultPort;
              description = "The loopback port this instance listens on; it is claimed, so two instances or services cannot share it.";
            };
            settings = lib.mkOption {
              type = settingsType;
              default = {};
              description = ''
                ${tool}'s settings, typed from its extracted facts. Secrets take
                redact references only; the service launcher renders the file
                with them at each start, so no secret reaches the Nix store.
                The instance fixes the settings derived from `port` and
                `stateDir`; setting another value for one fails evaluation.
              '';
            };
            stateDir = lib.mkOption {
              type = lib.types.strMatching "/.*";
              default = "${stateRoots.${backend}.value top}/${owner}/${name}";
              defaultText = lib.literalExpression ''"${stateRoots.${backend}.text}/${owner}/<name>"'';
              description = "Absolute directory for this instance's writable state, created 0700 at start.";
            };
          }
          // extraOptions;
        config.settings = derived {
          inherit name;
          config = top;
          instance = config;
        };
      }));
      default = {};
      description = ''
        Named ${tool} instances. Each runs as the service
        `${owner}-<name>` through `ai.services`, on Home Manager (a systemd
        user unit on Linux) and devenv (a process) alike.
      '';
    };

    config.ai.${owner}.services = lib.mapAttrs' (name: instance: let
      rendered = render instance.settings;
      state = map lib.escapeShellArg ([instance.stateDir] ++ directories instance);
      # The tool resolves relative paths (CLIProxyAPI's `.env` and `logs/`)
      # against its working directory, so it runs in its own state.
      run = strictShellApplication pkgs {
        name = "${owner}-${name}";
        text = ''
          ${pkgs.coreutils}/bin/mkdir -p ${toString state}
          ${pkgs.coreutils}/bin/chmod 0700 ${toString state}
          cd ${lib.escapeShellArg instance.stateDir}
          ${preStart instance}
          exec ${lib.getExe instance.package} ${argumentsOf instance}
        '';
      };
    in
      lib.nameValuePair "${owner}-${name}" {
        command = [(lib.getExe run)];
        inherit (instance) enable;
        # Manager Plus's render also returns the environment it reads.
        environment = rendered.environment or {};
        files.config = {
          inherit (rendered) content secrets;
          inherit variable;
        };
        ports.main = instance.port;
        restartOnChange = restartOnChange instance;
      })
    instances;
  };
}
