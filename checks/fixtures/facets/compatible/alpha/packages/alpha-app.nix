{
  bravo-tool,
  facetLib,
  lib,
  runCommandLocal,
  system,
}:
runCommandLocal "alpha-app" {
  nativeBuildInputs = [bravo-tool];
  passthru = {
    bravoDrvPath = bravo-tool.drvPath;
    decorated = "${facetLib.bravo.greeting}:alpha";
    inherit system;
  };
} ''
  test -e ${bravo-tool}/marker
  mkdir -p "$out"
  printf '%s\n' ${lib.escapeShellArg "${facetLib.bravo.greeting}:alpha"} > "$out/marker"
''
