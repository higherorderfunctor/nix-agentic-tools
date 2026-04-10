# Stacked-workflows devenv module (minimal stub).
#
# The HM module contributes skills and instructions to the shared
# ai.skills / ai.instructions pools. Under devenv, those pools are
# consumed by the same sharedOptions.nix → per-app devenvTransform
# chain. This stub exists so collectFacet ["modules" "devenv"] picks
# up the content package, and future devenv-specific config (e.g.,
# git config for project-local shells) has a home.
#
# Skills and instructions are contributed by the HM module via the
# shared option pools; the devenv side of each CLI reads from those
# same pools. No duplication needed here.
_: {}
