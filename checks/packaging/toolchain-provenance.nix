# Inspect compiler inputs and JS build/runtime references, including helpers.
# Every Go/Rust package must carry the locked overlay compiler, and no package
# or derivation-valued passthru helper (vendor, extractor) may carry nixpkgs'
# own go, rustc or cargo (no silent nixpkgs fallback).
{
  buildOverlay,
  inputs,
  lib,
  pkgs,
  self,
  ...
}: {
  checks.toolchain-provenance = let
    vu = import ../../lib/toolchains.nix {inherit inputs;};
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit
      (vu.mkGoToolchain {
        floor = "0";
        inherit pkgs;
        pname = "provenance";
      })
      go
      ;
    rust = (vu.mkRustPlatform {inherit pkgs;}).rust.rustc;
    # nixpkgs' default `go`, `rustc` and `cargo`, plus every versioned
    # `go_1_<N>`: a nixpkgs recipe builds with `buildGo<N>Module`, so its Go
    # is usually not `pkgs.go` (gh: go-1.27.1 while `go` is go-1.26.8).
    # A name that does not evaluate (removed or insecure) cannot be an input.
    forbidden = lib.concatMap (name: let
      probe = builtins.tryEval (builtins.seq pkgs.${name}.outPath pkgs.${name}.outPath);
    in
      lib.optional probe.success {
        inherit name;
        outPath = probe.value;
      }) (["cargo" "go" "rustc"] ++ builtins.filter (n: builtins.match "go_1_[0-9]+" n != null) (builtins.attrNames pkgs));
    packages = builtins.attrValues self.ciPackages.${system};
    nested = lib.concatMap (p:
      builtins.filter
      (value: lib.isDerivation value && value ? goModules)
      (builtins.attrValues (p.passthru or {})))
    packages;
    goPackages = builtins.filter (p: p ? goModules) (packages ++ nested);
    rustPackages = builtins.filter (p: p ? cargoDeps) packages;
    # Every derivation-valued passthru attr: vendor derivations and helpers
    # that compile on their own, e.g. glab's `extracted` schema extractor.
    helpers = lib.concatMap (p: builtins.filter lib.isDerivation (builtins.attrValues (p.passthru or {}))) packages;
    outPaths = drvs: map (d: d.outPath) (builtins.filter lib.isDerivation drvs);
    carriesBanned = label: p: deps:
      map (b: "${label}: ${p.name} carries nixpkgs ${b.name}")
      (builtins.filter (b: builtins.elem b.outPath (outPaths deps)) forbidden);
    audit = label: candidates: locked:
      lib.concatMap (p: let
        own = p.nativeBuildInputs or [];
      in
        lib.optional (!(builtins.elem locked.outPath (outPaths own))) "${label}: ${p.name} lacks locked ${locked.name}"
        ++ carriesBanned label p (own ++ p.goModules.nativeBuildInputs or []))
      candidates;
    # Mark the consumer's JS tools before applying our overlay. Our thin
    # toolchain overrides reset version/src, so parity with nixpkgs cannot
    # conceal a recipe that takes a bare consumer input.
    jsNames =
      builtins.filter
      (name: (name == "bun" || builtins.match "pnpm_[0-9]+" name != null) && builtins.hasAttr name pkgs)
      (builtins.attrNames pkgs.ai.generic);
    markedPkgs = import inputs.nixpkgs {
      inherit system;
      config.allowUnfree = true;
      overlays = [
        (_final: prev:
          lib.genAttrs jsNames (name:
            prev.${name}.overrideAttrs {
              version = "consumer-marker-${name}";
              __intentionallyOverridingVersion = true;
            }))
        # The recipe-level overlay, which builds on this marked set. The
        # exported overlay re-exports this flake's own builds and would
        # ignore the markers, making the audit vacuous.
        buildOverlay
      ];
    };
    jsForbidden =
      map (name: {
        inherit name;
        drvPath = builtins.unsafeDiscardStringContext markedPkgs.${name}.drvPath;
      })
      jsNames;
    # Stop at derivations: namespaces include scopes and passthru attrs that
    # must not be interpreted as package trees. Helpers may contain nested
    # components (all-mcps) as well as the pnpmDeps fetcher itself.
    derivations = value:
      if lib.isDerivation value
      then [value]
      else if builtins.isAttrs value
      then lib.concatMap derivations (builtins.attrValues value)
      else [];
    jsPackages =
      builtins.filter
      (p: !(builtins.elem p.outPath (map (name: markedPkgs.ai.generic.${name}.outPath) jsNames)))
      (derivations markedPkgs.ai);
    jsAudit = label: p: let
      # JSON coercion preserves contexts of build inputs AND interpolated
      # runtime paths in phases, without realizing any package output.
      context = builtins.getContext (builtins.toJSON p.drvAttrs);
      banned = builtins.filter (b: builtins.hasAttr b.drvPath context) jsForbidden;
    in
      map (b: "${label}: ${p.name} carries consumer ${b.name}") banned;
    jsFailures = lib.concatMap (p:
      jsAudit "JS" p
      ++ lib.concatMap (h: jsAudit "JS helper of ${p.name}" h)
      (builtins.filter lib.isDerivation (builtins.attrValues (p.passthru or {}))
        ++ derivations (p.passthru.components or {})
        ++ lib.optional (p ? pnpmDeps) p.pnpmDeps))
    jsPackages;
    failures =
      audit "Go" goPackages go
      ++ audit "Rust" rustPackages rust
      ++ lib.concatMap (h: carriesBanned "helper" h (h.nativeBuildInputs or [])) helpers
      ++ jsFailures;
  in
    assert goPackages != [] && rustPackages != [] && jsNames != [] && jsPackages != [];
    assert lib.assertMsg (failures == []) "compiler provenance mismatch: ${lib.concatStringsSep ", " failures}";
      pkgs.runCommand "toolchain-provenance" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        echo '${toString (builtins.length goPackages)} Go and ${toString (builtins.length rustPackages)} Rust compiler inputs match locked overlays; ${toString (builtins.length helpers)} passthru helpers carry no nixpkgs compiler; ${toString (builtins.length jsPackages)} JS-audited packages carry no consumer ${lib.concatStringsSep "/" jsNames}' > "$out"
      '';
}
