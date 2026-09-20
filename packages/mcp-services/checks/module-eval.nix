# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
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
    userAgent = "assertion-control";
  };
  expectedSettings = {
    ignoreRobotsTxt = false;
    proxyUrl = null;
    userAgent = "assertion-control";
  };
in {
  checks = {
    # tryEval cannot expose throw messages. Follow facet-mock-negative by
    # evaluating a subprocess and checking its stderr, with a passing control.
    module-mcp-settings-assertion-messages = let
      source = lib.fileset.toSource {
        root = ../../..;
        fileset = lib.fileset.unions [
          ../../../lib/credentials.nix
          ../../../lib/mcp.nix
          ../../../packages/fetch-mcp/modules/mcp-server.nix
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
          result = mcpLib.evalSettings "fetch-mcp" settings;
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
        '') (["MCP server fetch-mcp settings assertions failed:"] ++ map (entry: entry.message) (builtins.filter (entry: !entry.assertion) (assertionSettings false).assertions))}
        if grep -F -- "passing assertion must not appear" actual.stderr; then
          echo "FAIL: diagnostic includes a passing assertion" >&2
          exit 1
        fi
        echo "PASS: MCP assertion diagnostics contain both failing messages" > "$out"
      '';

    # Exercise the same settings in both arms; equality also rejects leaked metadata.
    module-mcp-settings-assertions = mkTest "mcp-settings-assertions" (
      let
        passing = builtins.tryEval (mcpLib.evalSettings "fetch-mcp" (assertionSettings true) == expectedSettings);
        failing = builtins.tryEval (builtins.deepSeq (mcpLib.evalSettings "fetch-mcp" (assertionSettings false)) true);
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
        && !(servers.serena-mcp.enable or true)
    );

    # Server option tree has expected structure.
    module-mcp-services-option-tree = mkTest "mcp-services-option-tree" (
      let
        result = evalHm {};
        inherit (result.config.services.mcp-servers) servers;
      in
        servers ? context7-mcp
        && servers ? effect-mcp
        && servers ? fetch-mcp
        && servers ? git-intel-mcp
        && servers ? git-mcp
        && servers ? github-mcp
        && servers ? gitlab-mcp
        && servers ? kagi-mcp
        && servers ? nixos-mcp
        && servers ? sequential-thinking-mcp
        && servers ? serena-mcp
        && servers ? sympy-mcp
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
            settings.credentials.file = "/run/secrets/gh-token";
          };
        };
        activation = result.config.home.activation.mcpRestartOnSecretRotation or null;
      in
        activation
        != null
        && lib.hasInfix "mcp-github-mcp.service" (activation.text or "")
        && lib.hasInfix "sha256sum" (activation.text or "")
        && lib.hasInfix "/run/secrets/gh-token" (activation.text or "")
    );

    # DRY-RUN INERTNESS. Every MUTATING command in the rotation script must be
    # routed through home-manager's `run` helper, which echoes instead of
    # executing when DRY_RUN is set. Reads stay unwrapped on purpose, so a dry
    # run still evaluates its conditions and can report accurately.
    #
    # The NEGATIVE assertion is the load-bearing one. `printf … > "$hash_file"`
    # is the exact form this replaced, and it is what a future "simplification"
    # of the tee would reintroduce: `run` wraps a COMMAND AND ITS ARGUMENTS, so
    # a shell redirection attached to it is performed by the CALLING shell and
    # writes on a dry run regardless. Writing the hash during a dry run is worse
    # than merely failing to be inert -- the next REAL activation then sees an
    # unchanged hash and skips a restart that was genuinely needed, so the dry
    # run silently destroys pending rotation work.
    #
    # The positive assertions double as the CONTROL for the negative: they prove
    # the infix match reaches this script at all, so a passing negative cannot
    # be a match against an empty or wrongly-scoped string.
    module-mcp-services-rotation-dry-run-routed = mkTest "mcp-services-rotation-dry-run-routed" (
      let
        result = evalHm {
          services.mcp-servers.servers.github-mcp = {
            enable = true;
            settings.credentials.file = "/run/secrets/gh-token";
          };
        };
        text = result.config.home.activation.mcpRestartOnSecretRotation.text or "";
        allLines = lib.splitString "\n" text;
        # COMMENT LINES ARE EXCLUDED, and that is not incidental tidiness: the
        # emitted script carries a comment naming `printf > "$hash_file"` as the
        # form to avoid, so a scan over raw lines matches the very prose warning
        # against the defect and fails a correct script. Same shape as the
        # repo's bare-commands scan, which is per-line and therefore reads
        # comments too.
        lines = lib.filter (l: builtins.match "[[:space:]]*#.*" l == null) allLines;
        # Matched per LINE and WITHOUT interpolating any store path. Building
        # the needle from `${pkgs.coreutils}` instead would drag store-path
        # string context into this check's own derivation, which nix rejects
        # outright -- the assertion cannot reference a store path.
        #
        # A line counts as wrapped when it STARTS with `run ` (the standalone
        # commands) or pipes into it (the tee write). Testing for a bare `run `
        # infix instead would be satisfied by an unrelated `--dry-run ` token on
        # the same line, which is a false pass rather than a stylistic nit.
        lstrip = l: let
          m = builtins.match "[[:space:]]*(.*)" l;
        in
          if m == null
          then l
          else builtins.head m;
        runWrapped = l: lib.hasPrefix "run " (lstrip l) || lib.hasInfix "| run --quiet " l;
        # UNIVERSALLY quantified, and that is the whole point. An existential
        # ("SOME line is wrapped") passes while an UNWRAPPED mutating command
        # sits beside a wrapped one, so reintroducing the defect next to the fix
        # would leave this green and DRY_RUN mutating again. `hits != []` is the
        # positive control that stops the `all` passing vacuously when a
        # fragment stops appearing at all -- without it, DELETING a command
        # would look like compliance.
        everyOccurrenceWrapped = frag: let
          hits = lib.filter (l: lib.hasInfix frag l) lines;
        in
          hits != [] && lib.all runWrapped hits;
      in
        # LINUX-GATED, deliberately. The module emits systemd user units only
        # on Linux, so on darwin the entry does
        # not exist, `text` is empty and every assertion below would be false --
        # a check that fails by construction on one required platform. The
        # sibling rotation test lacks this guard and is a recorded aarch64-darwin
        # failure blocking `--all-systems`; adding a second one would deepen that
        # blocker rather than merely inherit it.
        !pkgs.stdenv.hostPlatform.isLinux
        || (
          everyOccurrenceWrapped "/bin/mkdir -p"
          && everyOccurrenceWrapped "/bin/chmod 700"
          && everyOccurrenceWrapped "/bin/systemctl --user restart"
          && everyOccurrenceWrapped "/bin/tee -- \"$hash_file\""
          # The read-only `is-active` probe must stay UNWRAPPED: a dry run has
          # to evaluate its conditions to report accurately. Asserted so the
          # rule above is not "over-applied" into wrapping reads as well.
          && lib.any (l: lib.hasInfix "/bin/systemctl --user is-active" l && !(runWrapped l)) lines
          # ANY redirection at the hash file, whatever the spacing. A plain
          # substring test for the exact `> "$hash_file"` form matched only that
          # one spelling, so `>"$hash_file"` -- valid shell, identical effect --
          # walked straight through the assertion meant to forbid it. Matching
          # `>` followed by optional whitespace covers the no-space, extra-space
          # and append spellings alike.
          && !(lib.any (l: builtins.match ".*>[[:space:]]*\"\\$hash_file\".*" l != null) lines)
        )
    );

    # Helper-based credentials have no stable file to fingerprint, so they
    # contribute no rotation entry (the path-based restart cannot apply).
    module-mcp-services-rotation-skips-helper-creds = mkTest "mcp-services-rotation-skips-helper-creds" (
      let
        result = evalHm {
          services.mcp-servers.servers.github-mcp = {
            enable = true;
            settings.credentials.helper = "/run/wrappers/gh-token-helper";
          };
        };
      in
        !(result.config.home.activation ? mcpRestartOnSecretRotation)
    );

    # No credentialed services -> no rotation activation entry (inert).
    module-mcp-services-rotation-absent-without-creds = mkTest "mcp-services-rotation-absent-without-creds" (
      let
        result = evalHm {};
      in
        !(result.config.home.activation ? mcpRestartOnSecretRotation)
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
