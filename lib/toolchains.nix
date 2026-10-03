# Compiler helpers apply the locked toolchain functions to the supplied package set.
{inputs}: let
  inherit (import ./packaging.nix) mkGoFloorFix;
in {
  # Compiler versions come only from the locked overlays. A recorded source
  # floor validates the newest stable Go release; it never selects nixpkgs Go.
  #
  # `recipeFile` is for TRUNK-TRACKED packages, whose floor is a `goFloor`
  # literal in the recipe rather than a sidecar key. The returned `passthru`
  # then carries `fixGoFloor`; the rev-bump worker runs it after replacing
  # rev + src hash and before nix-update derives vendorHash, keeping the
  # literal synchronized with go.mod. The flake attribute must equal `pname`.
  mkGoToolchain = {
    floor,
    pkgs,
    pname,
    recipeFile ? null,
  }: let
    inherit (pkgs) lib;
    goBin = inputs.go-overlay.lib.mkGoBin pkgs;
    releases =
      builtins.filter
      (version: builtins.match "[0-9]+\\.[0-9]+(\\.[0-9]+)?" version != null)
      (builtins.attrNames goBin.versions);
    latest =
      if releases == []
      then throw "${pname}: the locked go-overlay contains no stable Go release"
      else lib.last (builtins.sort lib.versionOlder releases);
    go =
      if lib.versionAtLeast latest floor
      then goBin.versions.${latest}
      else throw "${pname}: needs Go >= ${floor}; locked go-overlay provides ${latest}. Update go-overlay.";
    withGo = builder: builder.override {inherit go;};
  in {
    inherit go;
    buildGoModule = withGo pkgs.buildGoModule;
    # Preserve the upstream recipe's builder, including versioned constructors
    # and their package-specific defaults. Only its compiler changes.
    overridePackage = package:
      package.override (args: let
        names =
          builtins.filter
          (name: builtins.match "buildGo[0-9]*Module" name != null)
          (builtins.attrNames args);
        name =
          if builtins.length names == 1
          then builtins.head names
          else throw "${pname}: expected one Go builder argument, found ${builtins.toString names}";
      in {${name} = withGo args.${name};});
    passthru = lib.optionalAttrs (recipeFile != null) {
      goFloor = floor;
      fixGoFloor = mkGoFloorFix {
        inherit pkgs pname recipeFile;
        attr = pname;
      };
    };
  };

  mkRustPlatform = {pkgs}: let
    rust = (inputs.rust-overlay.lib.mkRustBin {} pkgs).stable.latest.default;
  in
    pkgs.makeRustPlatform {
      cargo = rust;
      rustc = rust;
    };
}
