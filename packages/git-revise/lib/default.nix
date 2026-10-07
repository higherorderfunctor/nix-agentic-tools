{
  # `{lib, extracted ? <the committed sidecar>}: {options; leaves; report; revsetFunctions;}`
  # — the shared generator (lib/git-tool-settings) over git-revise's sidecar and rows.
  # Only the three `revise.*` keys become options; the git keys it reads
  # (rebase.autoSquash, commit.gpgSign, ...) stay raw git configuration.
  git-revise.settings = {
    lib,
    extracted ? builtins.fromJSON (builtins.readFile ../extracted.json),
  }:
    import ../../../lib/git-tool-settings {
      inherit extracted lib;
      rows = builtins.fromJSON (builtins.readFile ../extract/annotations.json);
      tool = "git-revise";
    };
}
