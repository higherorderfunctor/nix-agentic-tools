sources: final: _: let
  nv = sources.agnix;

  # agnix requires Rust edition 2024 (>= 1.91)
  rust = final.rust-bin.stable.latest.default;
  rustPlatform = final.makeRustPlatform {
    cargo = rust;
    rustc = rust;
  };
in {
  agnix = rustPlatform.buildRustPackage {
    pname = "agnix";
    inherit (nv) version src;
    inherit (nv) cargoHash;

    nativeBuildInputs = [final.pkg-config];
    buildInputs = final.lib.optionals final.stdenv.hostPlatform.isDarwin [
      final.darwin.apple_sdk.frameworks.Security
      final.darwin.apple_sdk.frameworks.SystemConfiguration
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
      license = final.lib.licenses.mit;
      mainProgram = "agnix";
    };
  };
}
