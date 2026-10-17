# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  redact = import ../../../lib/redact {inherit lib;};
  inherit (harness) evalHm mcpLib mkTest;

  assertionSettings = passing: {
    assertions = [
      {
        assertion = true;
        message = "passing assertion must not appear";
      }
      {
        assertion = passing;
        message = "first caller assertion failed";
      }
      {
        assertion = passing;
        message = "second caller assertion failed";
      }
    ];
  };
  expectedSettings = {
    repository = null;
  };
in {
  checks = {
    # Evaluate settings directly so a renderer-local throw cannot satisfy this test.
    module-mcp-gitlab-settings-mutex = let
      source = lib.fileset.toSource {
        root = ../../..;
        fileset = lib.fileset.unions [
          ../../../lib/credentials.nix
          ../../../lib/redact
          ../../../lib/runtime-values
          ../../../lib/mcp.nix
          ../../../packages/gitlab-mcp/modules/mcp-server.nix
        ];
      };
      probe = pkgs.writeText "gitlab-settings-mutex.nix" ''
        { credential ? "none", instance ? false, callerPassing ? true }:
        let
          lib = import ${pkgs.path}/lib;
          mcpLib = import ${source}/lib/mcp.nix { inherit lib; };
          redact = import ${source}/lib/redact { inherit lib; };
          settings = {
            assertions = [{ assertion = callerPassing; message = "gitlab caller assertion failed"; }];
            instanceUrl = if instance then "https://gitlab.example.com" else null;
          } // lib.optionalAttrs (credential != "none") {
            apiUrl = if credential == "file" then redact.file "/run/secrets/gitlab-url" else redact.command "/run/secrets/gitlab-url";
          };
          result = mcpLib.evalSettings "gitlab-mcp" settings;
        in
          builtins.deepSeq result (
            assert !(result ? assertions);
            assert result.instanceUrl == settings.instanceUrl;
            assert credential == "none" || result.apiUrl == settings.apiUrl;
            true
          )
      '';
    in
      pkgs.runCommandLocal "module-test-mcp-gitlab-settings-mutex" {
        nativeBuildInputs = [pkgs.nix];
      } ''
        export NIX_STATE_DIR="$TMPDIR/nix-state"
        mkdir -p "$NIX_STATE_DIR/profiles/per-user/$USER"
        for credential in none file command; do
          nix-instantiate --eval --strict ${probe} --argstr credential "$credential"
        done
        nix-instantiate --eval --strict ${probe} --arg instance true
        for credential in file command; do
          if nix-instantiate --eval --strict ${probe} --argstr credential "$credential" --arg instance true >actual.stdout 2>actual.stderr; then
            echo "FAIL: gitlab instanceUrl + apiUrl.$credential unexpectedly succeeded" >&2
            exit 1
          fi
          grep -F 'MCP server gitlab-mcp settings assertions failed:' actual.stderr
          grep -F 'settings.instanceUrl and settings.apiUrl are mutually exclusive' actual.stderr
        done
        # The server's passing assertion must not hide a failing caller assertion.
        if nix-instantiate --eval --strict ${probe} --arg callerPassing false >actual.stdout 2>actual.stderr; then
          echo "FAIL: gitlab caller assertion unexpectedly succeeded" >&2
          exit 1
        fi
        grep -F 'gitlab caller assertion failed' actual.stderr
        if grep -F 'mutually exclusive' actual.stderr; then
          echo "FAIL: diagnostic includes a passing server assertion" >&2
          exit 1
        fi
        echo "PASS: gitlab mutex rejects file/command conflicts; valid settings and caller assertions verified" | tee "$out"
      '';

    # tryEval cannot expose throw messages. Follow facet-mock-negative by
    # evaluating a subprocess and checking its stderr, with a passing control.
    module-mcp-settings-assertion-messages = let
      source = lib.fileset.toSource {
        root = ../../..;
        fileset = lib.fileset.unions [
          ../../../lib/credentials.nix
          ../../../lib/mcp.nix
          ../../../packages/git-intel-mcp/modules/mcp-server.nix
        ];
      };
      probe = pkgs.writeText "mcp-settings-assertions.nix" ''
        { passing ? false }:
        let
          lib = import ${pkgs.path}/lib;
          mcpLib = import ${source}/lib/mcp.nix { inherit lib; };
          settings = builtins.fromJSON (
            if passing
            then ${builtins.toJSON (builtins.toJSON (assertionSettings true))}
            else ${builtins.toJSON (builtins.toJSON (assertionSettings false))}
          );
          result = mcpLib.evalSettings "git-intel-mcp" settings;
        in
          if passing
          then assert result == builtins.fromJSON ${builtins.toJSON (builtins.toJSON expectedSettings)}; true
          else result
      '';
    in
      pkgs.runCommandLocal "module-test-mcp-settings-assertion-messages" {
        nativeBuildInputs = [pkgs.nix];
      } ''
        export NIX_STATE_DIR="$TMPDIR/nix-state"
        mkdir -p "$NIX_STATE_DIR/profiles/per-user/$USER"
        nix-instantiate --eval --strict ${probe} --arg passing true
        if nix-instantiate --eval --strict ${probe} --arg passing false >actual.stdout 2>actual.stderr; then
          echo "FAIL: failing MCP assertions unexpectedly succeeded" >&2
          exit 1
        fi
        ${lib.concatMapStringsSep "\n" (message: ''
          if ! grep -F -- ${lib.escapeShellArg message} actual.stderr; then
            cat actual.stderr >&2
            exit 1
          fi
        '') (["MCP server git-intel-mcp settings assertions failed:"] ++ map (entry: entry.message) (builtins.filter (entry: !entry.assertion) (assertionSettings false).assertions))}
        if grep -F -- "passing assertion must not appear" actual.stderr; then
          echo "FAIL: diagnostic includes a passing assertion" >&2
          exit 1
        fi
        echo "PASS: MCP assertion diagnostics contain both failing messages" > "$out"
      '';

    # Exercise the same settings in both arms; equality also rejects leaked metadata.
    module-mcp-settings-assertions = mkTest "mcp-settings-assertions" (
      let
        passing = builtins.tryEval (mcpLib.evalSettings "git-intel-mcp" (assertionSettings true) == expectedSettings);
        failing = builtins.tryEval (builtins.deepSeq (mcpLib.evalSettings "git-intel-mcp" (assertionSettings false)) true);
      in
        passing.success && passing.value && !failing.success
    );

    # ── services.mcp-servers module ──────────────────────────────────

    # Default: all servers are disabled.
    module-mcp-services-default-disabled = mkTest "mcp-services-default-disabled" (
      let
        result = evalHm {};
        inherit (result.config.services.mcp-servers) servers;
      in
        !(servers.context7-mcp.enable or true)
        && !(servers.github-mcp.enable or true)
        && !(servers.kagi-mcp.enable or true)
    );

    # Server option tree has expected structure.
    module-mcp-services-option-tree = mkTest "mcp-services-option-tree" (
      let
        result = evalHm {};
        inherit (result.config.services.mcp-servers) servers;
      in
        servers ? context7-mcp
        && servers ? effect-mcp
        && servers ? git-intel-mcp
        && servers ? github-mcp
        && servers ? gitlab-mcp
        && servers ? kagi-mcp
        && servers ? nixos-mcp
    );

    # tools output is empty when no servers enabled.
    module-mcp-services-tools-empty-when-disabled = mkTest "mcp-services-tools-empty-when-disabled" (
      let
        result = evalHm {};
      in
        result.config.services.mcp-servers.tools == {}
    );

    # mcpConfig output is empty when no servers enabled.
    module-mcp-services-mcpconfig-empty-when-disabled = mkTest "mcp-services-mcpconfig-empty-when-disabled" (
      let
        result = evalHm {};
      in
        result.config.services.mcp-servers.mcpConfig.mcpServers == {}
    );

    # Credential rotation: enabling a file-credentialed HTTP server emits a
    # restart-on-rotation activation entry that fingerprints the secret path
    # and targets the matching systemd user unit.
    module-mcp-services-rotation-restart-entry = mkTest "mcp-services-rotation-restart-entry" (
      let
        result = evalHm {
          services.mcp-servers.servers.github-mcp = {
            enable = true;
            settings.credentials = redact.file "/run/secrets/gh-token";
          };
        };
        activation = result.config.home.activation.ai-mcp-restart-on-secret-rotation or null;
      in
        !pkgs.stdenv.hostPlatform.isLinux
        || (
          activation
          != null
          && lib.hasInfix "mcp-github-mcp.service" (activation.text or "")
          && lib.hasInfix "sha256sum" (activation.text or "")
          && lib.hasInfix "/run/secrets/gh-token" (activation.text or "")
        )
    );

    # Layer 3 runs the whole rotation body through HM's dry-run helper.
    module-mcp-services-rotation-dry-run-routed = let
      result = evalHm {
        services.mcp-servers.servers.github-mcp = {
          enable = true;
          settings.credentials = redact.file "/build/token";
        };
      };
      systemctl = pkgs.writeShellScript "mcp-systemctl-fixture" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        case "$*" in
          "--user is-active --quiet mcp-github-mcp.service") exit 0 ;;
          "--user restart mcp-github-mcp.service") printf 'restart\n' >> "$XDG_STATE_HOME/restarts" ;;
          *) exit 1 ;;
        esac
      '';
      text = lib.replaceStrings ["${pkgs.systemd}/bin/systemctl"] ["${systemctl}"] (result.config.home.activation.ai-mcp-restart-on-secret-rotation.text or "");
    in
      if !pkgs.stdenv.hostPlatform.isLinux
      then mkTest "mcp-services-rotation-dry-run-routed" true
      else
        pkgs.runCommand "mcp-services-rotation-dry-run-routed" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          ${harness.hmRunShim}
          export HOME="$PWD/home" XDG_STATE_HOME="$PWD/state"
          printf first > /build/token
          export DRY_RUN=1
          ${text}
          test ! -e "$XDG_STATE_HOME"
          unset DRY_RUN
          ${text}
          hash_file="$XDG_STATE_HOME/nix-agentic-tools/mcp-cred-hashes/github-mcp"
          expected="$(${pkgs.coreutils}/bin/sha256sum /build/token | ${pkgs.coreutils}/bin/cut -d ' ' -f1)"
          test "$(${pkgs.coreutils}/bin/cat "$hash_file")" = "$expected"
          test "$(${pkgs.coreutils}/bin/stat -c %a "''${hash_file%/*}")" = 700
          ${text}
          test ! -e "$XDG_STATE_HOME/restarts"
          printf second > /build/token
          export DRY_RUN=1
          ${text}
          test "$(${pkgs.coreutils}/bin/cat "$hash_file")" = "$expected"
          test ! -e "$XDG_STATE_HOME/restarts"
          unset DRY_RUN
          ${text}
          expected="$(${pkgs.coreutils}/bin/sha256sum /build/token | ${pkgs.coreutils}/bin/cut -d ' ' -f1)"
          test "$(${pkgs.coreutils}/bin/cat "$hash_file")" = "$expected"
          test "$(${pkgs.coreutils}/bin/cat "$XDG_STATE_HOME/restarts")" = restart
          ${pkgs.coreutils}/bin/touch "$out"
        '';

    # Helper-based credentials have no stable file to fingerprint, so they
    # contribute no rotation entry (the path-based restart cannot apply).
    module-mcp-services-rotation-skips-helper-creds = mkTest "mcp-services-rotation-skips-helper-creds" (
      let
        result = evalHm {
          services.mcp-servers.servers.github-mcp = {
            enable = true;
            settings.credentials = redact.command "/run/wrappers/gh-token-helper";
          };
        };
      in
        !(result.config.home.activation ? ai-mcp-restart-on-secret-rotation)
    );

    # No credentialed services -> no rotation activation entry (inert).
    module-mcp-services-rotation-absent-without-creds = mkTest "mcp-services-rotation-absent-without-creds" (
      let
        result = evalHm {};
      in
        !(result.config.home.activation ? ai-mcp-restart-on-secret-rotation)
    );

    # Bridge servers run mcp-proxy, whose own --host default IS loopback — so
    # they were already safe, but by upstream happenstance rather than by
    # anything stated here, and service.host was discarded for all ten of
    # them. Assert we PIN it, so an upstream default change cannot silently
    # widen every bridge service at once.
    module-mcp-services-bridge-pins-bind-host = let
      # 127.0.0.2 is deliberately NOT mcp-proxy's own default (127.0.0.1), so a
      # match proves the value was threaded from service.host rather than merely
      # inherited from upstream — which is the entire point of pinning it.
      overridden = evalHm {
        services.mcp-servers.servers.context7-mcp = {
          enable = true;
          service.host = "127.0.0.2";
        };
      };
      defaulted = evalHm {
        services.mcp-servers.servers.context7-mcp.enable = true;
      };
      execOf = r: r.config.systemd.user.services.mcp-context7-mcp.Service.ExecStart;
      # Build the expected fragment with the SAME escaper the emitter uses, so
      # the two cannot disagree. Today `lib.escapeShellArg` leaves a dotted quad
      # bare (it only quotes strings outside `[[:alnum:],._+:@%/-]+`), so this
      # renders `--host 127.0.0.2` — but hardcoding either the bare or the
      # quoted form would turn a future change in that rule into a test failure
      # against a wrapper that is still correct.
      expectHost = h: lib.escapeShellArg "--host ${lib.escapeShellArg h}";
    in
      pkgs.runCommand "module-test-mcp-services-bridge-pins-bind-host" {} ''
        fail() {
          echo "FAIL: mcp-services-bridge-pins-bind-host: $1" >&2
          exit 1
        }
        o=${execOf overridden}
        d=${execOf defaulted}
        grep -qF -- '--host' "$d" || fail "mcp-proxy invoked without --host at all"
        grep -qF -- ${expectHost "127.0.0.2"} "$o" \
          || fail "bind host not threaded from an overridden service.host"
        grep -qF -- ${expectHost "127.0.0.1"} "$d" \
          || fail "default bind host is not loopback"
        grep -qF -- 'context7-mcp --transport stdio' "$o" \
          || fail "context7 bridge does not launch its working stdio transport"
        if grep -qF -- 'context7-mcp --transport stdio --port' "$o"; then
          fail "context7 bridge passes the proxy port to its stdio child"
        fi
        if grep -qF -- 'context7-mcp --transport http' "$o"; then
          fail "context7 bridge still launches its Upstash-only native HTTP transport"
        fi
        echo PASS > "$out"
      '';
  };
}
