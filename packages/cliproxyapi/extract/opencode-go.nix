{
  docs,
  pkgs,
}:
pkgs.runCommand "cliproxyapi-opencode-go-extracted" {} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :
  ${pkgs.python3}/bin/python3 ${../checks/opencode-go.py} ${./opencode-go.py}
  ${pkgs.python3}/bin/python3 ${./opencode-go.py} ${docs}/models.json > "$out"
''
