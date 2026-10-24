{
  docs,
  pkgs,
}: let
  python = pkgs.python3.withPackages (packages: [packages.markdown-it-py]);
in
  pkgs.runCommand "cliproxyapi-z-ai-extracted" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${python}/bin/python3 ${../checks/z-ai.py} ${./z-ai.py}
    ${python}/bin/python3 ${./z-ai.py} ${docs}/claude.md ${docs}/devpack-quick-start.md ${docs}/overview.md ${docs}/quick-start.md > "$out"
  ''
