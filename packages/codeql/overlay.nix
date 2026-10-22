# `ai.devTools.codeql.mkQueryPack` and `mkModelPack` beside the eleven engines:
# pack specs, plain data that no engine is read for. Only the two claimed
# leaves are returned, and the composer merges them into `ai.devTools.codeql`,
# so reading them forces no engine. See docs/customize.md.
{lib, ...}: {
  claims = [
    ["ai" "devTools" "codeql" "mkModelPack"]
    ["ai" "devTools" "codeql" "mkQueryPack"]
  ];
  overlay = _final: _prev: {
    ai.devTools.codeql = {inherit (import ./lib/specs.nix {inherit lib;}) mkModelPack mkQueryPack;};
  };
}
