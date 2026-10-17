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
{
  pkgs,
  packageLib,
  ...
}: let
  rustPlatform = packageLib.mkRustPlatform {inherit pkgs;};
  version = "0.3.0";
  src = pkgs.fetchFromGitHub {
    owner = "rvben";
    repo = "rumdl";
    tag = "v${version}";
    hash = "sha256-8NwDXhFHb2Vtw60+uqIjgr6mpXvq6YnZc0cM4hGkJEM=";
  };
in
  (pkgs.rumdl.override {inherit rustPlatform;}).overrideAttrs (finalAttrs: _: {
    inherit src version;
    cargoDeps = rustPlatform.fetchCargoVendor {
      # pname and version name the output, so a stale hash cannot reuse the
      # previous release's cached vendor set after a bump.
      inherit (finalAttrs) pname version src;
      hash = "sha256-YteF5h1LzeoTnC6179JrOjTEPzq8K3ZWOt719G+JXy4=";
    };
  })
