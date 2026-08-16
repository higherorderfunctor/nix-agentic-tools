{
  packages,
  pkgs,
  system,
  ...
}: {
  platform-omission = assert if system == "aarch64-darwin"
  then packages ? unsupported-control
  else !(packages ? unsupported-control);
    pkgs.runCommandLocal "facet-platform-omission" {} ''
      mkdir -p "$out"
      touch "$out/passed"
    '';
}
