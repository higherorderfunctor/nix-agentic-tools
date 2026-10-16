# Where a runtime record's builder-declared options live below `ai.<name>`.
#
# The record's `optionNamespaces` maps each option group the builder declares
# to a relative option path; an omitted group sits at the runtime root:
#
#   launcher  `package`, the launcher pools (`environmentVariables`, `shell`)
#             and, when nested, the runtime switch `enable`
#   pools     every other per-runtime pool option (`agents`, `context`,
#             `rules`, `skills`, `mcpServers`, `settings`, their `*Dir`
#             companions) and each pool's `normalized` form
#
# Kiro keeps its CLI launcher under `ai.kiro.cli`; Copilot reserves
# `ai.copilot.cli` for a launcher it does not ship yet and keeps github.com's
# pools under `ai.copilot.github`. Delivery options (`files`, `activation`,
# `checks`) and a runtime's own `options` are not grouped here.
#
# A launcher is a package. A record without `defaults.package` has none, so
# it declares no `package` option, installs nothing, and keeps its `enable`
# switch at the root even when its launcher namespace is reserved.
#
# Every reader takes the record and returns paths RELATIVE to `ai.<name>`:
# the builder, the delivery diagnostics, `option-paths.nix` and the policy
# facts all bind through here, so no caller re-derives a placement.
{lib}: let
  launcherPools = ["environmentVariables" "shell"];
  namespace = record: group: (record.optionNamespaces or {}).${group} or [];
  hasLauncher = record: (record.defaults or {}) ? package;
in {
  groups = ["launcher" "pools"];
  inherit hasLauncher;
  launcher = record: namespace record "launcher";
  pools = record: namespace record "pools";
  # The namespace holding a shared pool's per-runtime option.
  pool = record: pool:
    namespace record (
      if builtins.elem pool launcherPools
      then "launcher"
      else "pools"
    );
  # The settable runtime switch: beside a nested launcher, else the root.
  enable = record:
    lib.optionals (hasLauncher record) (namespace record "launcher") ++ ["enable"];
}
