# Per-package barrel for kiro-gateway.
#
# kiro-gateway is a binary-only package — no HM module, no factory.
# The derivation lives in overlays/kiro-gateway.nix. This barrel
# exists only to give the package a home for dev docs.
{
  docs = ./docs;
}
