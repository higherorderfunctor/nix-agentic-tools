{pkgs}: let
  sources = builtins.fromJSON (builtins.readFile ./z-ai-sources.json);
  docs = pkgs.lib.mapAttrs (_: source: pkgs.fetchurl source) sources;
  python = pkgs.python3.withPackages (packages: [packages.markdown-it-py]);
in
  pkgs.runCommand "cliproxyapi-z-ai-extracted" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${python}/bin/python3 ${../checks/z-ai.py} ${./z-ai.py}
    ${python}/bin/python3 ${./z-ai.py} ${docs.claude} ${docs.overview} ${docs.quick-start} > "$out"
  ''
