# Unified check suite.
# Superset of both source repos' checks.
# Implementation in Phase 3.7.
{
  lib,
  pkgs,
  self,
}: {
  # agent-configs — agnix --strict
  # formatting — dprint check
  # linting — deadnix, statix
  # module-eval — HM module evaluation tests
  # shell — shellcheck, shellharden, shfmt
  # spelling — cspell
  # structural — cross-reference validation
}
