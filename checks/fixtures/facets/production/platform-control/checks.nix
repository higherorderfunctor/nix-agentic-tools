{
  omittedPackages,
  packages,
  pkgs,
  system,
  ...
}: {
  platform-omission = assert if system == "aarch64-darwin"
  then packages ? unsupported-control
  else
    !(packages ? unsupported-control)
    && builtins.elem "unsupported-control" omittedPackages;
    pkgs.runCommandLocal "facet-platform-omission" {} ''
      mkdir -p "$out"
      touch "$out/passed"
    '';
}
