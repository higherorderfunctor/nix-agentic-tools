{pkgs, ...}: {
  placeholder = pkgs.runCommandLocal "facet-unsupported-metadata" {} "touch $out";
}
