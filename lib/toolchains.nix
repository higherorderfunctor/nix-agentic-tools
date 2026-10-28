# Compiler helpers apply the locked toolchain functions to the supplied package set.
{inputs}: let
  inherit (import ./packaging.nix) mkGoFloorFix;
  mkRustToolchain = {
    extensions ? [],
    pkgs,
  }:
    (inputs.rust-overlay.lib.mkRustBin {} pkgs).stable.latest.default.override {
      inherit extensions;
    };
in {
  inherit mkRustToolchain;

  # Compiler versions come only from the locked overlays. A recorded source
  # floor selects its matching stable Go release; it never selects nixpkgs Go.
  # Bare minors absent from the lock select their newest stable patch.
  # Missing floors require a recipe override; detected floors reject overrides.
  #
  # `recipeFile` is for TRUNK-TRACKED packages, whose floor is a `goFloor`
  # literal in the recipe rather than a sidecar key. The returned `passthru`
  # then carries `fixGoFloor`; the rev-bump worker runs it after replacing
  # rev + src hash and before nix-update derives vendorHash, keeping the
  # literal synchronized with go.mod. The flake attribute must equal `pname`.
  mkGoToolchain = {
    floor ? null,
    override ? null,
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
    detected = floor != null && floor != "" && floor != "0";
    requested =
      if detected && override != null
      then throw "${pname}: Go floor ${floor} is detected; remove the stale mkGoToolchain override from the recipe"
      else if detected
      then floor
      else if override != null
      then override
      else throw "${pname}: no Go floor detected; run fixGoFloor or declare mkGoToolchain override = \"latest\" or an exact version in the recipe";
    candidates =
      if !detected && requested == "latest"
      then releases
      else if builtins.elem requested releases
      then [requested]
      else if override == null && builtins.match "[0-9]+\\.[0-9]+" requested != null
      then builtins.filter (version: lib.hasPrefix "${requested}." version) releases
      else [];
    go =
      if candidates != []
      then goBin.versions.${lib.last (builtins.sort lib.versionOlder candidates)}
      else throw "${pname}: Go floor/override ${requested} matches no stable release in the lock; run nix flake update go-overlay";
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
    passthru =
      lib.optionalAttrs (override != null) {
        goToolchainOverride = override;
      }
      // lib.optionalAttrs (recipeFile != null) {
        goFloor = floor;
        fixGoFloor = mkGoFloorFix {
          inherit pkgs pname recipeFile;
          attr = pname;
        };
      };
  };

  mkRustPlatform = {pkgs}: let
    rust = mkRustToolchain {inherit pkgs;};
  in
    pkgs.makeRustPlatform {
      cargo = rust;
      rustc = rust;
    };
}
