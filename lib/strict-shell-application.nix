# `pkgs.writeShellApplication` in this repository's full strict mode: the
# `set -o` flags as `bashOptions`, so they precede the generated PATH export,
# the `inherit_errexit` shopt at the top of `text`, and the shared opt-in
# shellcheck flags, all read from `config/shell-strict.nix`. For a standalone
# script; a check body goes through ./mk-linted-check.nix instead.
pkgs: args: let
  shellStrict = import ../config/shell-strict.nix;
in
  pkgs.writeShellApplication (args
    // {
      inherit (shellStrict) bashOptions;
      extraShellCheckFlags = shellStrict.shellcheckFlags;
      text = ''
        ${shellStrict.shoptHeader}
        ${args.text}
      '';
    })
