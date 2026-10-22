# cpa-gate beyond its Go tests, which run in the package's check phase: the
# Caddy pin, the Caddyfile and policy through `caddy validate`, and a running
# gate whose log never carries a key.
{
  lib,
  pkgs,
  self,
  ...
}: let
  gate = import ../lib/gate.nix {inherit lib pkgs;};
  exe = lib.getExe self.ciPackages.${pkgs.stdenv.hostPlatform.system}.cpa-gate;
  strict = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
  '';
  # Caddy's config and data directories, kept inside the build.
  isolate = ''
    export HOME="$TMPDIR" XDG_CONFIG_HOME="$TMPDIR/config" XDG_DATA_HOME="$TMPDIR/data"
  '';
  caddyfile = port:
    gate.caddyfile {
      healthPort = port + 3;
      host = "127.0.0.1";
      inherit port;
      upstreamPort = 28463;
    };

  # Every key holds "SECRET", so one grep finds any of them in a log.
  entry = name: {
    apis = ["responses"];
    internal = "internal-SECRET-${name}";
    key = "client-SECRET-${name}";
    models = ["m"];
    inherit name;
  };
  policy = entries: lib.escapeShellArg (builtins.toJSON {inherit entries;});

  # null when go.mod requires the Caddy nixpkgs ships, else what differs.
  pinError = goMod: let
    found = builtins.filter (match: match != null) (map (builtins.match "[[:space:]]*github.com/caddyserver/caddy/v2 (v[^ ]+).*") (lib.splitString "\n" goMod));
  in
    if found == [["v${pkgs.caddy.version}"]]
    then null
    else "src/cpa-gate/go.mod requires Caddy ${builtins.toJSON found}, nixpkgs ships v${pkgs.caddy.version}";
  goMod = builtins.readFile ../src/cpa-gate/go.mod;
  wrongPin = lib.replaceStrings ["caddy/v2 v${pkgs.caddy.version}"] ["caddy/v2 v0.0.0"] goMod;
in {
  checks =
    {
      cliproxyapi-gate-pins = pkgs.runCommand "cliproxyapi-gate-pins" {} ''
        ${strict}
        ${lib.optionalString (pinError goMod != null) ''
          echo ${lib.escapeShellArg "FAIL: ${pinError goMod}"} >&2
          echo 'fix: "$(nix build --no-link --print-out-paths .#cpa-gate.updateScript)"' >&2
          exit 1
        ''}
        ${lib.optionalString (pinError wrongPin == null) ''
          echo "FAIL: the pin check accepted a go.mod requiring Caddy v0.0.0" >&2
          exit 1
        ''}
        touch "$out"
      '';

      # `caddy validate` adapts the Caddyfile and provisions the module,
      # which loads the policy, without listening.
      cliproxyapi-gate-validate = pkgs.runCommand "cliproxyapi-gate-validate" {} ''
        ${strict}
        ${isolate}
        printf '%s' ${policy [(entry "a")]} > good.json
        printf '%s' ${policy [(entry "a") ((entry "b") // {inherit (entry "a") key;})]} > shared.json
        # validate <policy path>. Caddy logs an error as JSON off a terminal,
        # so a message is matched without its quotes.
        validate() {
          env ${gate.policyVariable}="$1" ${exe} validate --config ${pkgs.writeText "cpa-gate.Caddyfile" (caddyfile 8080)} --adapter caddyfile 2>&1
        }
        # refused <policy path> <message>: validation fails with the message.
        refused() {
          local out
          if out=$(validate "$1"); then
            echo "FAIL: validated with policy '$1'" >&2
            exit 1
          fi
          case "$out" in
            *"$2"*) echo "ok: refused: $2" ;;
            *)
              echo "FAIL: policy '$1' refused without '$2':" >&2
              echo "$out" >&2
              exit 1
              ;;
          esac
        }

        validate "$PWD/good.json"
        refused "$PWD/shared.json" 'share a client key'
        refused "$PWD/absent.json" 'read failed'
        # An empty or unset variable substitutes nothing: no path at all.
        refused "" 'argument count'
        touch "$out"
      '';
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      # A running gate, and a site beside it whose upstream is down: the
      # gate refuses this request without a checked body; the 502 on the
      # other site makes Caddy log an error. Every credential carrier reaches
      # neither log. Controls drop each field and expose its unredacted keys;
      # Caddy itself redacts Authorization even with headers retained.
      cliproxyapi-gate-log = let
        withFailingSite =
          caddyfile 28461
          + lib.concatStringsSep "\n" [
            ""
            ":28462 {"
            "\tbind 127.0.0.1"
            "\treverse_proxy 127.0.0.1:28463"
            "}"
            ""
          ];
        without = field: lib.replaceStrings ["\t\t\t\t${field} delete\n"] [""] withFailingSite;
        config = name: text: pkgs.writeText "cpa-gate-${name}.Caddyfile" text;
      in
        pkgs.runCommand "cliproxyapi-gate-log" {} ''
          ${strict}
          ${isolate}
          printf '%s' ${policy [(entry "authorization") (entry "probe")]} > policy.json
          export ${gate.policyVariable}="$PWD/policy.json"
          # cspell:ignore noproxy
          curl() {
            ${pkgs.curl}/bin/curl --noproxy '*' --max-time 5 --silent --output /dev/null "$@"
          }

          # run <Caddyfile> <log>: send a key in each carrier to both sites.
          run() {
            ${exe} run --config "$1" --adapter caddyfile 2> "$2" &
            local pid=$! attempt port url header
            local auth_header='Authorization: Bearer client-SECRET-authorization'
            for attempt in {1..100}; do
              if curl http://127.0.0.1:28461/ && curl http://127.0.0.1:28462/; then
                break
              fi
              if ! kill -0 "$pid" 2>/dev/null || [ "$attempt" = 100 ]; then
                cat "$2" >&2
                echo "FAIL: cpa-gate did not start" >&2
                exit 1
              fi
              sleep 0.1
            done
            for port in 28461 28462; do
              url="http://127.0.0.1:$port/v1/responses"
              curl -X POST "$url?key=client-SECRET-probe"
              curl -X POST "$url?key=query-SECRET"
              curl -X POST "$url?auth_token=token-SECRET"
              curl -X POST --header "$auth_header" "$url"
              for header in 'X-Api-Key: header-SECRET' 'X-Goog-Api-Key: goog-SECRET'; do
                curl -X POST --header "$header" "$url"
              done
            done
            kill "$pid"
            wait "$pid" || :
          }
          # expect <log> <fixed string> <why>
          expect() {
            if ! grep -qF -- "$2" "$1"; then
              cat "$1" >&2
              echo "FAIL: $1 lacks $2: $3" >&2
              exit 1
            fi
          }

          run ${config "fixed" withFailingSite} fixed.log
          if grep -F SECRET fixed.log >&2; then
            echo "FAIL: a key reached the log" >&2
            exit 1
          fi
          expect fixed.log '"probe"' "the gate's own line for the known key"
          expect fixed.log '"authorization"' "the gate's own line for Authorization"
          expect fixed.log 'connection refused' "the error entry the filter must clean"

          run ${config "uri-kept" (without "request>uri")} uri-kept.log
          expect uri-kept.log token-SECRET "the control keeping request>uri"
          expect uri-kept.log query-SECRET "the control keeping request>uri"
          run ${config "headers-kept" (without "request>headers")} headers-kept.log
          expect headers-kept.log header-SECRET "the control keeping request>headers"
          expect headers-kept.log goog-SECRET "the control keeping request>headers"
          expect headers-kept.log '"authorization"' "Authorization reached the gate with Caddy's built-in redaction"
          if grep -F client-SECRET-authorization headers-kept.log >&2; then
            echo "FAIL: Authorization reached the retained-header log" >&2
            exit 1
          fi
          touch "$out"
        '';
    };
}
