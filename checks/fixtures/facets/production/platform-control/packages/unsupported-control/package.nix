{
  runCommandLocal,
  system,
}:
if system != "aarch64-darwin"
then throw "platform-negative package recipe was forced on ${system}"
else
  runCommandLocal "facet-platform-control" {} ''
    mkdir -p "$out"
    touch "$out/present"
  ''
