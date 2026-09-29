{
  # `{lib, extracted ? <the committed sidecar>}: {options; leaves; report; revsetFunctions;}`
  # — see settings.nix.
  git-branchless.settings = import ./settings.nix;
}
