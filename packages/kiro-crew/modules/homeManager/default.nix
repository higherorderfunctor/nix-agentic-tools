# Kiro Crew Home Manager integration. Options and every decision made from them
# are shared byte-for-byte with devenv; only backend-native effects differ.
import ../common.nix {
  installPackages = packages: {home.packages = packages;};

  installEnv = {
    enable,
    env,
    lib,
  }: {
    # Keep the home prefix unconditional so discovering the module's root
    # definitions never forces config. Omit sessionVariables altogether when
    # inactive: the shared eval harness does not declare that HM option, and
    # even mkIf false around an undeclared option fails its unmatched check.
    home = lib.optionalAttrs enable {sessionVariables = env;};
  };

  # SCOPED IN A SUBSHELL, deliberately. Home Manager concatenates every
  # activation DAG entry into one script it opens with `set -eu` + `set -o
  # pipefail`, so flags an entry sets persist into every later entry and into
  # home-manager's own code. The body has no parent-shell effects to lose —
  # no export, no cd, no trap — and failure still propagates, because the
  # subshell exits non-zero and the caller's `set -e` sees it.
  #
  # `entryAfter ["writeBoundary"]`: the seed writes outside the HM-managed
  # generation tree, which is exactly what the write boundary exists to order.
  installSeed = {
    lib,
    name,
    command,
  }: {
    home.activation.${name} = lib.hm.dag.entryAfter ["writeBoundary"] ''
      (
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${command}
      )
    '';
  };
}
