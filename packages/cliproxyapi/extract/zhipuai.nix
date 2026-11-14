{
  docs,
  pkgs,
}: let
  python = pkgs.python3.withPackages (packages: [packages.markdown-it-py]);
in
  pkgs.runCommand "cliproxyapi-zhipuai-extracted" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${python}/bin/python3 ${../checks/zhipuai.py} ${./zhipuai.py}
    ${python}/bin/python3 ${./zhipuai.py} ${docs}/claude.md ${docs}/overview.md ${docs}/quick-start.md > "$out"
  ''
