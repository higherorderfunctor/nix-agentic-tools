# rumdl: nixpkgs build recipe with release source and Cargo vendor pins.
# nix-update refreshes both hashes through the owner's update target.
#
# WHAT IT IS FOR HERE — read this before "simplifying" the pair. rumdl is
# the PRIMARY half of the markdown table-cell-count gate defined in
# `lib/markdown/table-cells.nix`; `markdownlint-cli2` is the backup half.
# They share the rule NUMBER (MD056) and cover DISJOINT halves of it:
# rumdl catches a header/delimiter disagreement (the break), markdownlint
# catches an over-wide body row (the cause) and goes blind on the break
# because its parser stops recognizing a table at all. Measured over this
# corpus with only MD056 enabled, rumdl runs in 0.04s against
# markdownlint's 8.2s, which is why the Rust one is primary. Neither is
# redundant; the markdown-formatting fragment carries the full rationale.
#
# NOT a formatter: `rumdl fmt` does not reflow, so prettier owns
# formatting (see `dev/fragments/markdown-formatting/`).
#
# Carried despite nixpkgs having it because nixpkgs' version is not an
# input to this repo's update cadence.
{pkgs, ...}: let
  version = "0.2.78";
  src = pkgs.fetchFromGitHub {
    owner = "rvben";
    repo = "rumdl";
    tag = "v${version}";
    hash = "sha256-Sr2CL1tCYrDYEQm3zcDY/3yzIjMCH1xg9tKpLovEK98=";
  };
in
  pkgs.rumdl.overrideAttrs (finalAttrs: _: {
    inherit src version;
    cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
      # pname and version name the output, so a stale hash cannot reuse the
      # previous release's cached vendor set after a bump.
      inherit (finalAttrs) pname version src;
      hash = "sha256-RJ1+G7xdbcXXLdkrV4xyFKsLtxwkRAJiFu16QSXQqUc=";
    };
  })
