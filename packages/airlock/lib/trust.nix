# The trust helper of an intercepting instance, registered as its proxy
# `trust` (lib/ai/proxy.nix): prints the path of the PEM bundle a client must
# trust. A client launcher passes its inherited extra-CA file, if any, and
# gets one bundle holding both for Claude's Bun runtime via NODE_EXTRA_CA_CERTS.
{
  lib,
  pkgs,
}: let
  services = import ../../ai-module/lib/services.nix {inherit lib;};
  strictShellApplication = import ../../../lib/strict-shell-application.nix;
in
  {
    caDirectory,
    service,
  }:
    strictShellApplication pkgs {
      name = "${service}-trust";
      text = ''
        ${services.runtimeDirectoryPath pkgs service}
        ca="$_ai_dir"/${lib.escapeShellArg caDirectory}/ca.pem
        # The service creates the CA before it listens; without one, a client
        # would start trusting nothing Airlock issues. The -L/-O checks refuse
        # a symlinked or foreign-owned runtime directory, such as one planted
        # at the shared TMPDIR fallback, before trusting its CA.
        if [ -L "$_ai_dir" ] || [ ! -O "$_ai_dir" ] || [ ! -s "$ca" ]; then
          printf '%s: no CA at %s; start %s before launching a client that trusts it.\n' ${lib.escapeShellArg service} "$ca" ${lib.escapeShellArg service} >&2
          exit 1
        fi
        inherited="''${1:-}"
        if [ -z "$inherited" ]; then
          printf '%s\n' "$ca"
          exit 0
        fi
        # A private, content-addressed bundle beside the CA's directory,
        # published by rename, so concurrent launches never read a partial one.
        umask 077
        bundle="$(${pkgs.coreutils}/bin/mktemp "$_ai_dir/.trust.XXXXXX")"
        trap '${pkgs.coreutils}/bin/rm -f -- "$bundle"' EXIT
        { ${pkgs.coreutils}/bin/cat -- "$inherited"; echo; ${pkgs.coreutils}/bin/cat -- "$ca"; } >"$bundle"
        sum="$(${pkgs.coreutils}/bin/sha256sum <"$bundle")"
        target="$_ai_dir/trust-''${sum%% *}.pem"
        ${pkgs.coreutils}/bin/mv -f -- "$bundle" "$target"
        printf '%s\n' "$target"
      '';
    }
