# Publish only the certificate outside the service's private runtime directory.
# The client helper returns a reusable bundle path; the launcher execs the client.
{
  caDirectory,
  lib,
  pkgs,
}: let
  services = import ../../ai-module/lib/services.nix {inherit lib;};
  publicationSuffix = ".trust";
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
            printf '%s: cannot jail client: CA key missing or inaccessible at %s; ensure %s is started with the same XDG_RUNTIME_DIR/TMPDIR and its private directory is accessible before launching.\n' ${lib.escapeShellArg service} "$_ai_ca_key" ${lib.escapeShellArg service} >&2
            exit 1
          fi
        '')
        (c.mask-path (c.noescape ''"$_ai_ca_key"''))
      ];
      text = ''
        ${services.runtimeDirectoryPath pkgs service}
        _ai_dir="$_ai_dir"${lib.escapeShellArg publicationSuffix}
        ca="$_ai_dir/ca.pem"
        # Refuse a symlinked or foreign-owned publication directory, including
        # one planted at the shared TMPDIR fallback.
        if [ -L "$_ai_dir" ] || [ ! -O "$_ai_dir" ] || [ -L "$ca" ] || [ ! -O "$ca" ] || [ ! -s "$ca" ]; then
          printf '%s: no CA at %s; start %s with the same XDG_RUNTIME_DIR/TMPDIR before launching.\n' ${lib.escapeShellArg service} "$ca" ${lib.escapeShellArg service} >&2
          exit 1
        fi
        inherited="$1"
        if [ -z "$inherited" ]; then
          printf '%s\n' "$ca"
          exit 0
        fi
        ${services.runtimeRootPath}
        _ai_dir="$_ai_root/airlock-trust"
        ${services.prepareRuntimeDirectory pkgs "Airlock client trust"}
        bundle="$(${pkgs.coreutils}/bin/mktemp "$_ai_dir/.bundle.XXXXXX")"
        trap '${pkgs.coreutils}/bin/rm -f -- "$bundle"' EXIT
        {
          ${pkgs.coreutils}/bin/cat -- "$inherited"
          printf '\n'
          ${pkgs.coreutils}/bin/cat -- "$ca"
        } >"$bundle"
        digest="$(${pkgs.coreutils}/bin/sha256sum <"$bundle")"
        target="$_ai_dir/''${digest%% *}.pem"
        if [ ! -f "$target" ]; then
          ${pkgs.coreutils}/bin/mv -- "$bundle" "$target"
        fi
        printf '%s\n' "$target"
      '';
    };
  publish = package: ''
    ca="$(${lib.getExe package} ca init "''${AIRLOCK_CONFIG%/*}"/${lib.escapeShellArg caDirectory})"
    _ai_dir="''${AIRLOCK_CONFIG%/*}"${lib.escapeShellArg publicationSuffix}
    ${services.prepareRuntimeDirectory pkgs "Airlock certificate publication"}
    certificate="$(${pkgs.coreutils}/bin/mktemp "$_ai_dir/.ca.XXXXXX")"
    trap '${pkgs.coreutils}/bin/rm -f -- "$certificate"' EXIT
    ${pkgs.coreutils}/bin/cat -- "$ca" >"$certificate"
    ${pkgs.coreutils}/bin/mv -f -- "$certificate" "$_ai_dir/ca.pem"
    trap - EXIT
  '';
}
