# One VM boot that runs every named case in ./test.py against the real units:
# standalone Home Manager generations built with sops-nix and this repository's
# Home Manager module, activated as the user through their own `activate`
# scripts, so sops-nix's restart step, Home Manager's sd-switch and
# ai-module's service reconcile step run in the order they run on a real host.
#
# Every generation shares two mock daemons from `ai.services`, named so one
# sorts before `sops-nix` and one after it, because sd-switch dispatches its
# starts in name order without waiting. Each daemon's launcher reads one
# `redact.file` secret, logs `saw <the value, shell-quoted>` and sleeps. A case
# adds a generation below and a function in ./test.py; it needs no new boot.
{
  home-manager,
  nix-agentic-tools,
  nixpkgs,
  sops-nix,
  ...
}: let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  inherit (pkgs) lib;
  inherit (nix-agentic-tools.lib) redact;
  strictShellApplication = import "${nix-agentic-tools}/lib/strict-shell-application.nix";

  user = "alice";
  uid = 1000;
  home = "/home/${user}";
  keyFile = "${home}/.config/sops/age/keys.txt";
  fixtures = lib.importJSON ./fixtures/values.json;

  reader = strictShellApplication pkgs {
    name = "secret-reader";
    runtimeInputs = [pkgs.coreutils];
    text = ''
      printf 'saw %q\n' "$READER_SECRET"
      exec sleep infinity
    '';
  };

  readers = {
    aa-reader.secret = "aa";
    zz-reader.secret = "zz";
  };

  # `secrets` names one set in fixtures/values.json, by default the
  # generation's own; `tag` is a literal in each launcher, so changing it
  # changes every reader's unit.
  generation = name: {
    daemons ? readers,
    extra ? {},
    secrets ? name,
    tag ? "base",
  }: let
    configuration = import "${home-manager}/lib/eval-config.nix" {
      inherit pkgs;
      modules = [
        "${sops-nix}/modules/home-manager/sops.nix"
        nix-agentic-tools.homeManagerModules.default
        ({config, ...}: {
          home = {
            homeDirectory = home;
            stateVersion = "26.11";
            username = user;
          };
          sops = {
            age.keyFile = keyFile;
            defaultSopsFile = "${sopsFiles}/${secrets}.yaml";
            secrets = lib.genAttrs (lib.unique (lib.mapAttrsToList (_: daemon: daemon.secret) daemons)) (_: {});
          };
          ai.services =
            lib.mapAttrs (_: daemon: {
              command = [(lib.getExe reader)];
              environment = {
                READER_SECRET = redact.file config.sops.secrets.${daemon.secret}.path;
                READER_TAG = tag;
              };
            })
            daemons;
        })
        extra
      ];
    };
  in {
    path = configuration.activationPackage;
    # What each daemon must log once it has read this generation's value.
    readers = lib.mapAttrs (_: daemon: fixtures.secrets.${secrets}.${daemon.secret}) daemons;
  };

  generations = lib.mapAttrs generation {
    base = {};
    # Unreadable by the test identity: see sopsFiles. sops-nix adds its
    # activation step with no DAG edge, so its place against reloadSystemd is
    # a tie-break; a real host ran it first. Pinned here: the step restarts the
    # provider from the unit systemd still has loaded, which succeeds, and only
    # the reload's run of the new unit fails, a failure sd-switch ignores. The
    # lower-priority `data` keeps sops-nix's own body.
    broken.extra.home.activation.sops-nix = {
      after = [];
      before = ["reloadSystemd"];
      data = lib.mkOptionDefault "";
    };
    changed.tag = "changed";
    fresh.daemons = readers // {aa-fresh.secret = "fresh";};
    rotate-aa = {};
    rotate-zz = {};
    # Logs every call to $HOME/systemctl-calls, then runs the real systemctl.
    systemctl-path = {
      secrets = "base";
      extra.systemd.user.systemctlPath = "${strictShellApplication pkgs {
        name = "systemctl";
        text = ''
          printf '%s\n' "$*" >> "$HOME/systemctl-calls"
          exec ${pkgs.systemd}/bin/systemctl "$@"
        '';
      }}/bin/systemctl";
    };
  };

  # A throwaway age identity and every set in fixtures/values.json encrypted to
  # it, made at build time; the sets under `foreign` go to a second identity
  # that is never kept, so nothing can decrypt them.
  sopsFiles = pkgs.runCommand "service-secret-ordering-secrets" {nativeBuildInputs = [pkgs.age pkgs.sops];} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    mkdir "$out"
    age-keygen -o "$out/identity.txt" 2>/dev/null
    age-keygen -o foreign.txt 2>/dev/null
    ${lib.concatLines (lib.mapAttrsToList (name: values: let
        key =
          if builtins.elem name fixtures.foreign
          then "foreign.txt"
          else ''"$out/identity.txt"'';
      in ''
        printf '%s' ${lib.escapeShellArg (builtins.toJSON values)} >${name}.json
        sops encrypt --age "$(age-keygen -y ${key})" --input-type json --output-type yaml ${name}.json >"$out/${name}.yaml"
      '')
      fixtures.secrets)}
  '';
  identity = "${sopsFiles}/identity.txt";
  cases = pkgs.writeText "service-secret-ordering.json" (builtins.toJSON {
    inherit generations home identity keyFile uid user;
  });
in
  pkgs.testers.runNixOSTest {
    name = "service-secret-ordering";
    nodes.machine = {
      users.users.${user} = {
        inherit home uid;
        isNormalUser = true;
      };
      virtualisation = {
        additionalPaths = [sopsFiles] ++ lib.mapAttrsToList (_: generation: generation.path) generations;
        memorySize = 2048;
      };
    };
    testScript = "CASES = ${builtins.toJSON "${cases}"}\n" + builtins.readFile ./test.py;
  }
