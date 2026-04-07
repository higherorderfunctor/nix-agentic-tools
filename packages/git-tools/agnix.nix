# `{inputs}` is threaded through by packages/git-tools/default.nix
# so Phase 3.3 can switch build inputs to
# `ourPkgs = import inputs.nixpkgs { ... }` for cache-hit parity.
# Not yet consumed in this file; plumbing-only for now.
_: sources: final: _: let
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
      final.apple-sdk_15
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
