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
in {
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
