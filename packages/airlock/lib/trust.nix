# A client trusts an intercepting instance's certificate where `airlock ca init`
# wrote it. The client helper returns a reusable bundle path; the launcher execs
# the client.
{
  home,
  lib,
  pkgs,
}: let
  strictShellApplication = import ../../../lib/strict-shell-application.nix;
  coreutils = "${pkgs.coreutils}/bin";
  # The base the service's `airlock ca init` uses: devenv's AIRLOCK_HOME, or on
  # Home Manager the XDG default even when the client's environment sets one.
  base =
    if home == null
    then "-u AIRLOCK_HOME"
    else "AIRLOCK_HOME=${lib.escapeShellArg home}";
  # Shell setting `variable` to the instance's CA directory as Airlock resolves
  # and refuses it, so a client trusts no directory init would refuse: under
  # AIRLOCK_HOME that is the canonical path, which a symlink swapped after init
  # cannot redirect.
  locate = {
    name,
    package,
    variable,
  }: ''
    if ! ${variable}="$(${coreutils}/env ${base} ${lib.getExe package} ca directory --instance ${lib.escapeShellArg name})"; then
      exit 1
    fi
  '';
in {
  helper = {
    name,
    package,
    service,
  }: let
    noCa = ca: "printf '%s: no CA at %s; start %s before launching.\\n' ${lib.escapeShellArg service} ${ca} ${lib.escapeShellArg service} >&2; exit 1";
    noKey = key: "printf '%s: cannot jail client: CA key missing or inaccessible at %s; start %s before launching.\\n' ${lib.escapeShellArg service} ${key} ${lib.escapeShellArg service} >&2; exit 1";
  in
    strictShellApplication pkgs {
      name = "${service}-trust";
      # Keep the fail-closed key mask; trust reads only the certificate.
      passthru.jailPermissions = c: [
        (c.add-runtime ''
          ${locate {
            inherit name package;
            variable = "_ai_ca_directory";
          }}
          _ai_ca_key="$_ai_ca_directory/ca.key"
          if [ ! -f "$_ai_ca_key" ]; then
            ${noKey ''"$_ai_ca_key"''}
          fi
        '')
        (c.mask-path (c.noescape ''"$_ai_ca_key"''))
      ];
      text = ''
        ${locate {
          inherit name package;
          variable = "directory";
        }}
        ca="$directory/ca.pem"
        if [ ! -s "$ca" ]; then
          ${noCa ''"$ca"''}
        fi
        inherited="$1"
        if [ -z "$inherited" ]; then
          printf '%s\n' "$ca"
          exit 0
        fi
        # A bundle lives beside the CA it extends, so it lasts as long as the CA.
        umask 077
        bundle="$(${coreutils}/mktemp "$directory/.bundle.XXXXXX")"
        trap '${coreutils}/rm -f -- "$bundle"' EXIT
        {
          ${coreutils}/cat -- "$inherited"
          printf '\n'
          ${coreutils}/cat -- "$ca"
        } >"$bundle"
        digest="$(${coreutils}/sha256sum <"$bundle")"
        target="$directory/''${digest%% *}.pem"
        if [ ! -f "$target" ]; then
          ${coreutils}/mv -- "$bundle" "$target"
        fi
        printf '%s\n' "$target"
      '';
    };
}
