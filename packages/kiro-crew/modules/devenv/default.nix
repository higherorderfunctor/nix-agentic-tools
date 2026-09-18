# Kiro Crew devenv integration. Options and every decision made from them are
# shared byte-for-byte with Home Manager; only backend-native effects differ.
import ../common.nix {
  installPackages = packages: {inherit packages;};

  installEnv = {
    enable,
    env,
    lib,
  }: {env = lib.mkIf enable env;};

  # A TASK, not `enterShell`. A task body is rendered as a standalone script,
  # so it carries the full strict-mode header of its own; an `enterShell` body
  # is `eval`'d into the developer's interactive shell, where `set -e` would
  # arm their session. That is the same split the repo's shell standard draws,
  # and it is why this hook exists rather than both backends sharing one string.
  # Only `command` is consumed here: `name` is the Home Manager activation-entry
  # key and `lib` is what that backend needs for its DAG helper. Accepting and
  # ignoring the rest keeps ONE hook signature across both backends, which is
  # the point — a per-backend signature would be a place for them to drift.
  installSeed = {command, ...}: {
    tasks."kirocrew:seed-pptx-engine" = {
      # `name` is the HM activation-entry key and has no devenv analogue; the
      # task name is the namespaced string devenv requires.
      before = ["devenv:enterShell"];
      exec = ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${command}
      '';
    };
  };
}
