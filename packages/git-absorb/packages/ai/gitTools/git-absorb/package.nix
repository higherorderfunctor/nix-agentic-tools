# Argument shape adapted from legacy 3-layer curried pattern during Milestone 6 port.
#
# `passthru.extracted` is the config-key census of the source this recipe
# builds (packages/git-absorb/extract/, lib/git-tool-settings). passthru is
# not a derivation input, so it does not move this package's store path.
{
  gitToolExtraction,
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  inherit (pkgs) fetchFromGitHub;

  vu = packageLib;

  rustToolchainChannel = "";
  rustPlatform = vu.mkRustPlatform {
    channel = rustToolchainChannel;
    inherit pkgs;
    override = "latest";
    pname = "git-absorb";
    recipeFile = repoPath ./package.nix;
  };

  rev = "debdcd28d9db2ac6b36205bda307b6693a6a91e7";
  src = fetchFromGitHub {
    owner = "tummychow";
    repo = "git-absorb";
    inherit rev;
    hash = "sha256-jAR+Vq6SZZXkseOxZVJSjsQOStIip8ThiaLroaJcIfc=";
  };
  extraction = gitToolExtraction {inherit pkgs;};

  package = pkgs.git-absorb.override (_: {
    rustPlatform.buildRustPackage = args:
      rustPlatform.buildRustPackage (finalAttrs: let
        a = (pkgs.lib.toFunction args) finalAttrs;
      in
        a
        // {
          version = vu.mkVersion {
            # upstream: readCargoVersion @ Cargo.toml
            upstream = "0.9.0";
            inherit rev;
          };
          inherit src;
          cargoHash = "sha256-8uCXk5bXn/x4QXbGOROGlWYMSqIv+/7dBGZKbYkLfF4=";
          doInstallCheck = true;
          installCheckPhase = ''
            runHook preInstallCheck
            $out/bin/git-absorb --version
            runHook postInstallCheck
          '';
        });
  });

  patchedSource = extraction.patchedSource {
    name = "git-absorb";
    inherit package;
  };
in
  package.overrideAttrs (prev: {
    passthru =
      (prev.passthru or {})
      // rustPlatform.passthru
      // {
        inherit patchedSource;
        # asciidoc parses Documentation/git-absorb.adoc, the source of the
        # option descriptions, the same way the build turns it into the man
        # page.
        extracted = extraction.extracted {
          name = "git-absorb";
          source = patchedSource;
          extractDir = ../../../../extract;
          tools = [pkgs.asciidoc];
        };
      };
  })
