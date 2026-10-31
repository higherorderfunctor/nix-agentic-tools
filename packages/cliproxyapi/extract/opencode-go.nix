{
  docs,
  pkgs,
}: let
  python = pkgs.python3.withPackages (packages: [packages.markdown-it-py]);
in
  pkgs.runCommand "cliproxyapi-opencode-go-extracted" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${python}/bin/python3 ${../checks/opencode-go.py} ${./opencode-go.py}
    ${python}/bin/python3 ${./opencode-go.py} ${docs}/models.json ${docs}/go.md > "$out"
  ''
