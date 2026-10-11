{
  # `{lib, extracted ? <the committed sidecar>}: {options; leaves; report; revsetFunctions;}`
  # — the shared generator (lib/git-tool-settings) over git-absorb's sidecar and rows.
  # No hand tables: the measured `minimum` already bounds `absorb.maxStack`.
  git-absorb.settings = {
    lib,
    extracted ?
      import ../../../lib/git-tool-settings/extracted.nix {
        dir = ../extracted;
        inherit lib;
      },
  }:
    import ../../../lib/git-tool-settings {
      inherit extracted lib;
      rows = builtins.fromJSON (builtins.readFile ../extract/annotations.json);
      tool = "git-absorb";
    };
}
