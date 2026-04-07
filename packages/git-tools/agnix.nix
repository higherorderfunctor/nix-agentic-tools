# Instantiate `ourPkgs` from `inputs.nixpkgs` so every build input
# (rust toolchain, makeRustPlatform, pkg-config, darwin SDK) routes
# through this repo's pinned nixpkgs instead of the consumer's. This
# is what gives the store path cache-hit parity against CI's
# standalone build — see dev/fragments/overlays/cache-hit-parity.md
# and dev/notes/overlay-cache-hit-parity-fix.md.
{inputs}: sources: final: _prev: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final) system;
    overlays = [(import inputs.rust-overlay)];
    config.allowUnfree = true;
  };
  nv = sources.agnix;

  # agnix requires Rust edition 2024 (>= 1.91)
  rust = ourPkgs.rust-bin.stable.latest.default;
  rustPlatform = ourPkgs.makeRustPlatform {
    cargo = rust;
    rustc = rust;
  };
in {
  agnix = rustPlatform.buildRustPackage {
    pname = "agnix";
    inherit (nv) version src;
    inherit (nv) cargoHash;

    nativeBuildInputs = [ourPkgs.pkg-config];
    buildInputs = ourPkgs.lib.optionals ourPkgs.stdenv.hostPlatform.isDarwin [
      ourPkgs.apple-sdk_15
    ];

    # Build all binary crates: agnix (CLI), agnix-lsp, agnix-mcp
    cargoBuildFlags = ["-p" "agnix-cli" "-p" "agnix-lsp" "-p" "agnix-mcp"];
    cargoTestFlags = ["-p" "agnix-cli" "-p" "agnix-lsp" "-p" "agnix-mcp"];

    # Telemetry test fails in Nix sandbox (no $HOME / no network)
    checkFlags = ["--skip" "test_telemetry_enable_disable_roundtrip"];

    passthru.mcpBinary = "agnix-mcp";

    meta = {
      description = "Linter, LSP, and MCP server for AI coding assistant config files";
      homepage = "https://github.com/agent-sh/agnix";
      license = ourPkgs.lib.licenses.mit;
      mainProgram = "agnix";
    };
  };
}
