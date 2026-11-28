{
  runCommandLocal,
  system,
}:
# Filtering after evaluating recipes would force this on an omitted system.
if system != "aarch64-darwin"
then throw "platform-negative package recipe was forced on ${system}"
else
  runCommandLocal "facet-platform-control" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    touch "$out"
  ''
