# Per-package barrel for any-buddy.
#
# any-buddy is the buddy worker source tree, consumed by claude-code's
# activation script. Binary-only package (no modules); buddy user
# options live in packages/claude-code/lib/mkClaude.nix. This barrel
# exists only to give the package a home for dev docs.
{
  docs = ./docs;
}
