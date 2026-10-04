# Repository pin, independent of consumer overrides of the Kimchi executable.
{
  pkgs,
  source ? (builtins.fromJSON (builtins.readFile ../sources.json)).extraction.workflowsPackage,
}:
pkgs.fetchzip {
  inherit (source) hash url;
  name = "kimchi-workflows-${source.version}-source";
}
