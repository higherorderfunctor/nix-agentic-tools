# Fill owners supply their installed Reader modules and one literal pair.
# Run the command in the same interpreter as both credential transports.
{
  pkgs,
  python-stack,
  name,
  ownerModules,
  pair,
  entry,
  extraPackages ? [],
}: let
  moduleArgs = {inherit pkgs python-stack;};
  credentialUsage = (import ./default.nix).ai.credential-usage.pythonModule moduleArgs;
  cpa = (import ../../cliproxyapi/lib/default.nix {inherit (pkgs) lib;}).ai.cliproxyapi.pythonModule moduleArgs;
  python = python-stack.withPackages (ps: [ps.pydantic ps.urllib3 credentialUsage cpa] ++ ownerModules);
in
  pkgs.runCommand name {
    nativeBuildInputs = [pkgs.bash python] ++ extraPackages;
    passthru = {inherit python;};
    READER_ENTRY = entry;
    READER_PAIR = pair;
  } ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    python3 -I -B ${../checks/conformance}/run.py "$READER_PAIR" "$READER_ENTRY"
    touch "$out"
  ''
