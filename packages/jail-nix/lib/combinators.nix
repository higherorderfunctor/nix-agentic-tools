# Repository combinators over jail.nix, for `extend { additionalCombinators =
# combinators pkgs; }`. Each is a raw `state -> state` permission, as
# `additionalCombinators` expects; upstream's `{sig; doc; impl}` records are
# only its own file format.
#
# The runtime snippets run in the jail's wrapper BEFORE bwrap starts, so they
# see the host. They are spliced into one script in permission order, and
# `strict-runtime` is meant to come first.
pkgs: combinators: let
  inherit (combinators) add-runtime escape unsafe-add-raw-args;
  services = import ../../ai-module/lib/services.nix {inherit (pkgs) lib;};
in {
  # Prepare airlock's launch inputs on the host, before bwrap. The gateway
  # service wrote the token file; this reads only its rendered client path.
  airlock-client = {
    client,
    destination ? "/etc/ssl/certs/ca-certificates.crt",
    entry,
    instance,
    port,
  }:
    add-runtime ''
              ${services.runtimeDirectoryPath pkgs "airlock-${instance}" entry}
              if [ -L "$_ai_dir" ] || [ ! -d "$_ai_dir" ] || [ ! -O "$_ai_dir" ] || [ ! -s "$_ai_dir/config.json" ]; then
                printf 'airlock: service config is unavailable: %s/config.json\n' "$_ai_dir" >&2
                exit 1
              fi
              _ai_token_file="$(${pkgs.jq}/bin/jq -er --arg client ${escape client} '.clients[$client].token_file // empty' "$_ai_dir/config.json")" || {
                printf 'airlock: selected client is absent from service config: %s\n' ${escape client} >&2
                exit 1
              }
              if [ ! -f "$_ai_token_file" ] || [ -L "$_ai_token_file" ] || [ ! -s "$_ai_token_file" ]; then
                printf 'airlock: client token file is unavailable: %s\n' "$_ai_token_file" >&2
                exit 1
              fi
              if [ -z "$_ai_runtime_xdg" ] || [ "''${_ai_runtime_xdg#/}" = "$_ai_runtime_xdg" ] || [ -L "$_ai_runtime_xdg" ] || [ ! -d "$_ai_runtime_xdg" ] || [ ! -O "$_ai_runtime_xdg" ]; then
                printf 'airlock: XDG_RUNTIME_DIR must be an absolute owned directory\n' >&2
                exit 1
              fi
              _ai_ca="$_ai_runtime_xdg/airlock-${toString port}/ca.pem"
              if [ ! -s "$_ai_ca" ]; then
                printf 'airlock: CA is unavailable: %s\n' "$_ai_ca" >&2
                exit 1
              fi
              _ai_roots="''${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"
              if [ ! -s "$_ai_roots" ]; then
                printf 'airlock: system roots are unavailable: %s\n' "$_ai_roots" >&2
                exit 1
              fi
              _ai_ca_dest="$(${pkgs.coreutils}/bin/realpath -e -- ${escape destination})" || {
                printf 'airlock: system CA destination is unavailable\n' >&2
                exit 1
              }
              _ai_bundle="$_ai_runtime_xdg/airlock-launch.$(${pkgs.python3}/bin/python3 -c 'import secrets; print(secrets.token_hex(24))')"
              _ai_bundle_created=1
              _ai_prior_exit="$(trap -p EXIT)"
              _ai_prior_hup="$(trap -p HUP)"
              _ai_prior_int="$(trap -p INT)"
              _ai_prior_term="$(trap -p TERM)"
              _ai_cleanup_bundle() {
                if [ "$_ai_bundle_created" -eq 1 ]; then
                  ${pkgs.coreutils}/bin/rm -f -- "$_ai_bundle"
                fi
              }
              _ai_run_prior_trap() {
                if [ -n "$1" ]; then
                  eval "set -- ''${1#trap -- }"
                  eval "$1"
                fi
              }
              _ai_on_bundle_exit() {
                local _ai_status="$?"
                trap - EXIT
                _ai_cleanup_bundle
                _ai_run_prior_trap "$_ai_prior_exit"
                return "$_ai_status"
              }
              _ai_on_bundle_signal() {
                local _ai_signal_status="$1"
                local _ai_prior_signal="$2"
                trap - HUP INT TERM
                _ai_cleanup_bundle
                _ai_run_prior_trap "$_ai_prior_signal"
                exit "$_ai_signal_status"
              }
              trap _ai_on_bundle_exit EXIT
              trap '_ai_on_bundle_signal 129 "$_ai_prior_hup"' HUP
              trap '_ai_on_bundle_signal 130 "$_ai_prior_int"' INT
              trap '_ai_on_bundle_signal 143 "$_ai_prior_term"' TERM
              if ! (umask 077; set -C; : > "$_ai_bundle"); then
                _ai_bundle_created=0
                printf 'airlock: cannot create private CA bundle\n' >&2
                exit 1
              fi
              exec {_ai_bundle_fd}<> "$_ai_bundle"
              ${pkgs.coreutils}/bin/rm -- "$_ai_bundle"
              _ai_bundle_created=0
              if [ -n "$_ai_prior_exit" ]; then eval "$_ai_prior_exit"; else trap - EXIT; fi
              if [ -n "$_ai_prior_hup" ]; then eval "$_ai_prior_hup"; else trap - HUP; fi
              if [ -n "$_ai_prior_int" ]; then eval "$_ai_prior_int"; else trap - INT; fi
              if [ -n "$_ai_prior_term" ]; then eval "$_ai_prior_term"; else trap - TERM; fi
              if ! ${pkgs.coreutils}/bin/cat -- "$_ai_roots" >&"$_ai_bundle_fd"; then
                printf 'airlock: system roots cannot be read: %s\n' "$_ai_roots" >&2
                exit 1
              fi
              printf '\n' >&"$_ai_bundle_fd"
              if ! ${pkgs.coreutils}/bin/cat -- "$_ai_ca" >&"$_ai_bundle_fd"; then
                printf 'airlock: CA cannot be read: %s\n' "$_ai_ca" >&2
                exit 1
              fi
              exec {_ai_bundle_read_fd}< "/proc/self/fd/$_ai_bundle_fd"
              exec {_ai_bundle_fd}>&-
              RUNTIME_ARGS+=(--ro-bind-data "$_ai_bundle_read_fd" "$_ai_ca_dest")
              unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
              HTTPS_PROXY="$(${pkgs.python3}/bin/python3 - "$_ai_token_file" ${escape client} ${escape (toString port)} <<'PY'
      import sys
      from urllib.parse import quote_from_bytes

      with open(sys.argv[1], "rb") as stream:
          token = stream.read()
      if not token:
          raise SystemExit("airlock: client token file is empty")
      client = quote_from_bytes(sys.argv[2].encode(), safe="")
      secret = quote_from_bytes(token, safe="")
      print(f"http://{client}:{secret}@127.0.0.1:{sys.argv[3]}")
      PY
              )"
              export HTTPS_PROXY
    '';
  # Mask a host path in the jail, resolved at launch: through `realpath`
  # first, so a symlinked credential is masked at its target. A directory
  # becomes an empty tmpfs; a file becomes an empty read-only file
  # (`/dev/null` cannot stand in: the bind is nodev, so opening it fails
  # with EACCES). A path that does not exist at launch is skipped.
  mask-path = path:
    add-runtime ''
      if jail_mask="$(realpath -e -- ${escape path} 2>/dev/null)"; then
        if [ -d "$jail_mask" ]; then
          RUNTIME_ARGS+=(--tmpfs "$jail_mask")
        else
          RUNTIME_ARGS+=(--ro-bind ${pkgs.emptyFile} "$jail_mask")
        fi
      fi
    '';

  # jail.nix's wrapper is a writeShellApplication with coreutils as its only
  # runtime input, so it prepends coreutils to PATH. Hand the jailed program
  # the PATH its caller had. Expand at exec, after the runtime snippets have
  # used coreutils. Keep this argument before later unset-env permissions;
  # upstream finalizes explicit set-env permissions after both.
  restore-path = unsafe-add-raw-args ''--setenv PATH "''${PATH#${pkgs.coreutils}/bin:}"'';

  # The repository's strict header for the runtime snippets after it. The
  # wrapper is its own process, so the header governs only that script.
  strict-runtime = add-runtime ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
  '';

  # Remove one variable from the jailed program's environment.
  unset-env = name: unsafe-add-raw-args "--unsetenv ${escape name}";
}
