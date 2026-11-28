# cspell:ignore batchmode preflight sembleignore
# End-to-end module contracts; the shared harness discovers every backend.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) checkRows evalDevenv evalHm mkTest rejectsChange;
  inherit (import ../../chatgpt-codex/checks/helpers.nix {inherit lib pkgs harness;}) hmCodexSettings;
  redact = import ../../../lib/redact {inherit lib;};

  hmDefault = evalHm {};
  devenvDefault = evalDevenv {};
  publicHost = "gitlab.example.com";
  enabled = {
    enable = true;
    host = publicHost;
  };
  tokenFile = redact.file "/run/secrets/gitlab-token";
  linux = pkgs.stdenv.hostPlatform.isLinux;
  nonLinuxMessage = "glab.keyringSync.enable currently requires Linux Secret Service and systemd user units.";

  # These probes observe what the wrapper sends to the executable, not which
  # arguments live glab accepts. An empty log cannot pass a successful call.
  stub = (pkgs.writeShellScriptBin "glab" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    {
      printf '<%s>' "$@"
      printf '\n'
    } >> "$GLAB_STUB_LOG"
    if [ "$1" = environment ]; then
      printf '%s\n' "''${GITLAB_HOST-}" "''${GITLAB_TOKEN-}" "''${GLAB_GIT_PROTOCOL-}" "''${BRAND_NEW_KEY-}"
    fi
  '').overrideAttrs (_: {version = "0-test";});
  mkWrapped = configDir: host:
    import ../lib/mkGlab.nix {
      inherit lib pkgs;
      cfg = {
        inherit configDir host;
        enable = true;
        extraSettings = {};
        package = stub;
        settings = {};
      };
    };
  mkRuntimeTest = name: probe:
    pkgs.runCommand "module-test-glab-${name}" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      export HOME="$PWD/home"
      export GLAB_STUB_LOG="$PWD/glab.log"
      : > "$GLAB_STUB_LOG"

      expect() {
        local row=$1 expected=$2 actual=$3
        if [ "$actual" != "$expected" ]; then
          printf 'FAIL: %s\nexpected:\n%s\nactual:\n%s\n' "$row" "$expected" "$actual" >&2
          exit 1
        fi
      }

      ${probe}
      echo PASS > "$out"
    '';
  # Build-relative paths are hermetic even on Darwin with no private /tmp.
  # Keep each seed run in its own fresh directory so stale state can't pass.
  ipv6Dir = "glab-ipv6-cfg";
  preflightDir = "glab-preflight-cfg";
in {
  checks =
    {
      module-glab-codex-sandbox-grants-effective-configdir = mkTest "glab-codex-sandbox-grants-effective-configdir" (
        let
          base = {
            ai.codex = {
              enable = true;
              native.settings.sandbox_mode = "workspace-write";
            };
            glab = enabled;
          };
          hm = hmCodexSettings (evalHm base);
          devenv = (evalDevenv (base // {glab = enabled // {configDir = "/tmp/explicit";};})).config;
        in
          checkRows "Glab config directory is writable in the Codex sandbox" {
            "Home Manager grants the resolved global directory rather than null" =
              builtins.elem "/home/test/.config/glab-cli" hm.sandbox_workspace_write.writable_roots;
            "devenv grants the explicit directory rather than assuming the Home Manager path" =
              builtins.elem "/tmp/explicit" devenv.ai.codex.files.".codex/config.toml".content.value.sandbox_workspace_write.writable_roots;
          }
      );

      # The one intentional configDir difference is a facet default, not an
      # option declaration difference. A project must be able to override it.
      module-glab-configdir-facet-defaults = mkTest "glab-configdir-facet-defaults" (
        let
          hm = (evalHm {glab = enabled;}).config.glab;
          devenv = (evalDevenv {glab = enabled;}).config.glab;
        in
          checkRows "Glab config directory defaults" {
            "Home Manager leaves the user-global default to glab" = hm.configDir == null;
            "devenv isolates config from the user-global directory" = devenv.configDir == "/tmp/devenv-state/glab-cli";
          }
      );

      module-glab-default-disabled = mkTest "glab-default-disabled" (checkRows "Glab opt-in" {
        "Home Manager does not install glab when disabled" = hmDefault.config.home.packages == [];
      });

      module-glab-devenv-installs-wrapper = mkTest "glab-devenv-installs-wrapper" (
        let
          packages = (evalDevenv {glab = enabled // {package = stub;};}).config.packages;
        in
          # A single unwrapped executable must not pass as the installed wrapper.
          map (package: package.name) packages == ["glab-wrapped-0-test"]
      );

      # Both facets deliberately share the same option declarations.
      module-glab-hm-devenv-option-parity = mkTest "glab-hm-devenv-option-parity" (
        let
          names = ev: builtins.attrNames (builtins.removeAttrs ev.options.glab ["_module"]);
        in
          names hmDefault == names devenvDefault
      );

      module-glab-keyring-sync-boundaries = mkTest "glab-keyring-sync-boundaries" (
        let
          # Force the actual module assertions and select Glab's diagnostics,
          # not unrelated assertions from other modules the harness imports.
          failed = eval: glab:
            map (entry: entry.message)
            (builtins.filter (entry: !entry.assertion && lib.hasPrefix "glab." entry.message) (eval {inherit glab;}).config.assertions);
          valid =
            enabled
            // {
              keyringSync.enable = true;
              token = tokenFile;
            };
          hmFailures = glab: extra:
            lib.sort builtins.lessThan (failed evalHm glab)
            == lib.sort builtins.lessThan (lib.optional (!linux) nonLinuxMessage ++ extra);
        in
          checkRows "Glab keyring synchronization boundaries" {
            "Home Manager accepts configured keyring sync on Linux only" = hmFailures valid [];
            "Home Manager rejects keyring sync without an enabled wrapper" =
              hmFailures (valid // {enable = false;}) ["glab.keyringSync.enable requires glab.enable."];
            "Home Manager rejects keyring sync without a host to associate with the token" =
              hmFailures (valid // {host = null;}) ["glab.keyringSync.enable requires glab.host so the token cannot be stored for the wrong instance."];
            "Home Manager rejects keyring sync without a token reference" =
              hmFailures (valid // {token = null;}) ["glab.keyringSync.enable requires glab.token as a redact reference."];
            "devenv rejects owning the graphical-session service" =
              failed evalDevenv valid
              == ["glab.keyringSync.enable is Home Manager-only: devenv may consume a user's existing keyring, but a repository shell must not own login or graphical-session services."];
          }
      );

      module-glab-literal-credentials-rejected = mkTest "glab-literal-credentials-rejected" (
        let
          # Force only the option under test, changing only its value from a
          # working redact reference so an unrelated failure cannot pass.
          rejectsLiteral = name: reference:
            rejectsChange (value: (evalHm {glab.${name} = value;}).config.glab.${name}) {
              valid = reference;
              invalid = "literal-token";
              expected = reference;
            };
          jobCommand = redact.command "/run/wrappers/bin/job-token";
        in
          checkRows "Glab credential value types" {
            "Home Manager accepts a literal public host, unlike credentials" =
              (evalHm {glab.host = publicHost;}).config.glab.host == publicHost;
            "Home Manager refuses a literal job token in place of a command" = rejectsLiteral "job_token" jobCommand;
            "Home Manager refuses a literal token in place of a file" = rejectsLiteral "token" tokenFile;
          }
      );

      # With all three environment paths absent, the strict wrapper must not
      # die on bash's bare unbound-variable error or reach the executable.
      module-glab-preflight-no-home = let
        wrapped = mkWrapped null publicHost;
      in
        mkRuntimeTest "preflight-no-home" ''
          status=0
          got=$(env -u HOME -u XDG_CONFIG_HOME -u GLAB_CONFIG_DIR \
            ${wrapped}/bin/glab version 2>&1) || status=$?
          expect 'unset config paths are rejected' 1 "$status"
          expect 'unset config paths get the actionable diagnostic, not nounset' \
            'glab: cannot locate a config directory — HOME, XDG_CONFIG_HOME and GLAB_CONFIG_DIR are all unset; set glab.configDir to name one explicitly' "$got"
          expect 'config directory guard stops before exec' "" "$(cat "$GLAB_STUB_LOG")"
        '';

      module-glab-preflight-runtime = let
        wrapped = mkWrapped preflightDir "https://gitlab.example.com/some/path";
        ipv6 = mkWrapped ipv6Dir "http://[2001:db8::1]/gitlab";
      in
        mkRuntimeTest "preflight-runtime" ''
          run() {
            local wrapper=$1
            : > "$GLAB_STUB_LOG"
            "$wrapper/bin/glab" version >/dev/null
          }
          calls() { cat "$GLAB_STUB_LOG"; }
          mode() { ${pkgs.coreutils}/bin/stat -c '%a' "$1"; }
          cfg=${preflightDir}

          run ${wrapped}
          expect 'new config directory is private' 700 "$(mode "$cfg")"
          seed=$'<config><set><--host><gitlab.example.com><api_protocol><https>\n<version>'

          printf 'hosts:\n  gitlab.example.com:\n' > "$cfg/config.yml"
          chmod 664 "$cfg/config.yml"
          run ${wrapped}
          expect 'existing group-readable config is repaired even on the fast path' 600 "$(mode "$cfg/config.yml")"
          expect 'the existing exact hostname prevents a repeated seed' '<version>' "$(calls)"

          # A regex would treat the dots as wildcards, skipping a missing entry.
          printf 'hosts:\n  gitlab-example-com:\n' > "$cfg/config.yml"
          run ${wrapped}
          expect 'hyphens are not a match for the dots in the real hostname' "$seed" "$(calls)"

          # Keep the historical bracket regression: an ERE with only dots
          # escaped did not find a literal bracketed IPv6 entry on a later run.
          run ${ipv6}
          expect 'HTTP IPv6 URL preserves brackets and selects http rather than hardcoded https' \
            $'<config><set><--host><[2001:db8::1]><api_protocol><http>\n<version>' "$(calls)"
          printf 'hosts:\n    [2001:db8::1]:\n' > ${ipv6Dir}/config.yml
          run ${ipv6}
          expect 'IPv6 host brackets are literal on the fast path' '<version>' "$(calls)"
        '';

      # Extraction establishes the upstream schema; this checks the module's
      # lowering, including a boolean and the categories that must stay out.
      module-glab-settings-generated-from-schema = mkTest "glab-settings-generated-from-schema" (
        let
          settings = hmDefault.options.glab.settings.type.getSubOptions [];
        in
          checkRows "Glab generated settings" {
            "a boolean setting is not lowered as a string" = rejectsChange (value: (evalHm {glab.settings.check_update = value;}).config.glab.settings.check_update) {
              valid = false;
              invalid = "false";
              expected = false;
            };
            "custom headers are not offered as a single environment setting" = !(settings ? custom_headers);
            "glamour style is available outside the core host and protocol settings" = settings ? glamour_style;
            "host is not duplicated among plain settings" = !(settings ? host);
            "job token is not available as a plain setting" = !(settings ? job_token);
            "personal token is not available as a plain setting" = !(settings ? token);
            "schema lowering keeps more than the defaulted subset" = builtins.length (builtins.attrNames (builtins.removeAttrs settings ["_module"])) > 20;
          }
      );

      module-glab-wrapper-reads-secrets-at-runtime = let
        # A command reference keeps the test hermetic: redact.file requires an
        # absolute non-store path, while this fixture only owns its build dir.
        readEnv = name:
          redact.command "${pkgs.writeShellScript "read-glab-${name}" ''
            set -euETo pipefail
            shopt -s inherit_errexit 2>/dev/null || :
            variable=${lib.escapeShellArg name}
            printf '%s' "''${!variable}"
          ''}";
        packagesFor = host: token:
          (evalHm {
            glab = {
              inherit host token;
              configDir = "glab-env-cfg";
              enable = true;
              extraSettings.brand_new_key = "value with spaces";
              package = stub;
              settings.git_protocol = "ssh";
            };
          }).config.home.packages;
        packages = packagesFor (readEnv "GLAB_TEST_HOST") (readEnv "GLAB_TEST_TOKEN");
        wrapped = builtins.head packages;
        # Read the source, not the store path (which would cause IFD), for
        # stable absolute file references and the historical duplicate export.
        exports = builtins.filter (line: line == "export GITLAB_HOST") (lib.splitString "\n" wrapped.passthru.wrapperText);
        fileScript = (builtins.head (packagesFor (redact.file "/run/secrets/gitlab-url") tokenFile)).passthru.wrapperText;
      in
        assert checkRows "Glab wrapper wiring" {
          "Home Manager installs only the wrapped executable" = map (package: package.name) packages == ["glab-wrapped-0-test"];
          "normal invocations resolve the host file at launch" = lib.hasInfix ''GITLAB_HOST="$('' fileScript && lib.hasInfix "redact-read glab.host file /run/secrets/gitlab-url" fileScript;
          "normal invocations resolve the token file at launch" = lib.hasInfix ''GITLAB_TOKEN="$('' fileScript && lib.hasInfix "redact-read glab.token file /run/secrets/gitlab-token" fileScript;
          "the secret and plain settings do not both export the host" = exports == ["export GITLAB_HOST"];
        };
          mkRuntimeTest "wrapper-reads-secrets-at-runtime" ''
            export GLAB_TEST_HOST=gitlab.example.com GLAB_TEST_TOKEN=first-test-token
            got=$(${wrapped}/bin/glab environment)
            expect 'seeding uses the host resolved at launch' \
              $'<config><set><--host><gitlab.example.com><api_protocol><https>\n<environment>' "$(cat "$GLAB_STUB_LOG")"
            # The wrapper exports the preferred GLAB_ spelling.
            expect 'the executable receives the runtime host, token, preferred protocol and extra setting' \
              $'gitlab.example.com\nfirst-test-token\nssh\nvalue with spaces' "$got"
            export GLAB_TEST_TOKEN=rotated-test-token
            got=$(${wrapped}/bin/glab environment)
            expect 'the same wrapper resolves a rotated reference on the next invocation' \
              $'gitlab.example.com\nrotated-test-token\nssh\nvalue with spaces' "$got"
          '';
    }
    // lib.optionalAttrs linux {
      module-glab-keyring-sync-hm-wiring = mkTest "glab-keyring-sync-hm-wiring" (
        let
          ev = evalHm {
            glab = {
              enable = true;
              host = redact.file "/run/secrets/gitlab-url";
              keyringSync.enable = true;
              settings.git_protocol = "ssh";
              token = tokenFile;
            };
          };
          pendingFile = "/home/test/.local/state/glab/keyring-sync-pending";
          sync = import ../lib/mkKeyringSync.nix {
            cfg = ev.config.glab;
            configDir = "/home/test/.config/glab-cli";
            inherit lib pendingFile pkgs;
          };
          activation = ev.config.home.activation.ai-glab-keyring-sync.text;
          pathUnit = ev.config.systemd.user.paths.glab-keyring-sync;
          service = ev.config.systemd.user.services.glab-keyring-sync;
          wrapper = (builtins.head ev.config.home.packages).passthru.wrapperText;
          # Inspect the generated source without realizing it during evaluation.
          # Pin both reader calls after (and absent before) the Secret Service probe.
          probeParts = lib.splitString "secret-tool store" sync.scriptText;
          readsAfterProbe = read:
            builtins.length probeParts
            == 2
            && !lib.hasInfix read (builtins.head probeParts)
            && lib.hasInfix read (builtins.elemAt probeParts 1);
        in
          checkRows "Glab keyring synchronization wiring" {
            "activation and path unit use the same pending marker" =
              lib.hasInfix pendingFile activation && pathUnit.Path.PathExists == pendingFile;
            "login receives the token over stdin rather than inheriting it in the environment" =
              lib.hasInfix ''printf '%s' "$glab_sync_token"'' sync.scriptText
              && lib.hasInfix "--stdin" sync.scriptText
              && !lib.hasInfix "export glab_sync_token" sync.scriptText;
            "login requests keyring storage instead of plaintext config" =
              lib.hasInfix "--use-keyring" sync.scriptText && !lib.hasInfix "--insecure-storage" sync.scriptText;
            "ordinary invocations retain the host but do not override the synchronized token" =
              !lib.hasInfix "export GITLAB_TOKEN" wrapper && lib.hasInfix "export GITLAB_HOST" wrapper;
            "path unit starts the synchronization service only in the graphical session" =
              pathUnit.Install.WantedBy == ["graphical-session.target"] && pathUnit.Path.Unit == "glab-keyring-sync.service";
            "service runs the synchronizer once without retries and bounds a stalled prompt" =
              toString service.Service.ExecStart
              == toString sync.script
              && service.Service.Type == "oneshot"
              && service.Service.Restart == "no"
              && service.Service.TimeoutStartSec == "5min";
            "service probes the keyring before reading the host secret" = readsAfterProbe "redact-read glab.host file /run/secrets/gitlab-url";
            "service probes the keyring before reading the token secret" = readsAfterProbe "redact-read glab.token file /run/secrets/gitlab-token";
          }
      );
    };
}
