# Publish only the certificate outside the service's private runtime directory.
# A client helper composes trust in its own temporary directory and supervises
# the command so the bundle survives until exit, including forwarded signals.
{
  caDirectory,
  lib,
  pkgs,
}: let
  services = import ../../ai-module/lib/services.nix {inherit lib;};
  strictShellApplication = import ../../../lib/strict-shell-application.nix;
in {
  helper = service:
    strictShellApplication pkgs {
      name = "${service}-trust";
      # Keep the existing fail-closed key mask; trust reads only the sibling.
      passthru.jailPermissions = c: [
        (c.add-runtime ''
          ${services.runtimeDirectoryPath pkgs service}
          _ai_ca_key="$_ai_dir"/${lib.escapeShellArg caDirectory}/ca.key
          if [ ! -f "$_ai_ca_key" ]; then
            printf '%s: cannot jail client: CA key missing at %s; start %s with the same XDG_RUNTIME_DIR/TMPDIR before launching.\n' ${lib.escapeShellArg service} "$_ai_ca_key" ${lib.escapeShellArg service} >&2
            exit 1
          fi
        '')
        (c.mask-path (c.noescape ''"$_ai_ca_key"''))
      ];
      text = ''
        ${services.runtimeDirectoryPath pkgs service}
        _ai_dir="$_ai_dir.trust"
        ca="$_ai_dir/ca.pem"
        # Refuse a symlinked or foreign-owned publication directory, including
        # one planted at the shared TMPDIR fallback.
        if [ -L "$_ai_dir" ] || [ ! -O "$_ai_dir" ] || [ -L "$ca" ] || [ ! -O "$ca" ] || [ ! -s "$ca" ]; then
          printf '%s: no CA at %s; start %s with the same XDG_RUNTIME_DIR/TMPDIR before launching.\n' ${lib.escapeShellArg service} "$ca" ${lib.escapeShellArg service} >&2
          exit 1
        fi
        umask 077
        exec ${pkgs.python3}/bin/python3 ${./client-trust.py} "$ca" "$@"
      '';
    };
  publish = package: ''
    ca="$(${lib.getExe package} ca init "''${AIRLOCK_CONFIG%/*}"/${lib.escapeShellArg caDirectory})"
    _ai_dir="''${AIRLOCK_CONFIG%/*}.trust"
    ${services.prepareRuntimeDirectory pkgs "airlock-trust"}
    certificate="$(${pkgs.coreutils}/bin/mktemp "$_ai_dir/.ca.XXXXXX")"
    trap '${pkgs.coreutils}/bin/rm -f -- "$certificate"' EXIT
    ${pkgs.coreutils}/bin/cat -- "$ca" >"$certificate"
    ${pkgs.coreutils}/bin/mv -f -- "$certificate" "$_ai_dir/ca.pem"
    trap - EXIT
  '';
}
