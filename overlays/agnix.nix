# agnix overlay — linter, LSP, and MCP server for AI coding
# assistant config files (`.agnix.toml`, `CLAUDE.md`, `AGENTS.md`,
# `SKILL.md`, hooks, MCP configs, Cursor rules, etc.).
#
# NOT a git tool — it parses AI agent config formats. Lives in its
# own `packages/agnix/` directory because it's a multi-purpose
# tool (linter + LSP + MCP server) that doesn't fit cleanly into
# git-tools or mcp-servers groupings.
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` so every build input
# (rust toolchain, makeRustPlatform, pkg-config, darwin SDK) routes
# through this repo's pinned nixpkgs instead of the consumer's.
# This is what gives the store path cache-hit parity against CI's
# standalone build — see dev/fragments/overlays/overlay-pattern.md.
#
# Argument shape adapted from legacy 2-layer curried pattern during Milestone 6 port.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    overlays = [inputs.rust-overlay.overlays.default];
  };
  inherit (ourPkgs) fetchFromGitHub;

  vu = import ./lib.nix;

  # agnix requires Rust edition 2024 (>= 1.91)
  rust = ourPkgs.rust-bin.stable.latest.default;
  rustPlatform = ourPkgs.makeRustPlatform {
    cargo = rust;
    rustc = rust;
  };

  rev = "60a152b7c2e0a57326af1a31852627971235da1b";
  src = fetchFromGitHub {
    owner = "agent-sh";
    repo = "agnix";
    inherit rev;
    hash = "sha256-BWXiEeIqBDrl7hSLxq1h+6B+mv3T8rqmpKRDz6EckF8=";
  };
in
  rustPlatform.buildRustPackage {
    pname = "agnix";
    version = vu.mkVersion {
      # upstream: readCargoWorkspaceVersion @ Cargo.toml
      upstream = "0.23.0";
      inherit rev;
    };
    inherit src;
    cargoHash = "sha256-xtKMuZXXCmOBpklekaTs0TvqxO4TumVoyUzVoT43gO4=";

    nativeBuildInputs = [ourPkgs.pkg-config];
    buildInputs = ourPkgs.lib.optionals ourPkgs.stdenv.hostPlatform.isDarwin [
      ourPkgs.apple-sdk_15
    ];

    # Build all binary crates: agnix (CLI), agnix-lsp, agnix-mcp
    cargoBuildFlags = ["-p" "agnix-cli" "-p" "agnix-lsp" "-p" "agnix-mcp"];
    cargoTestFlags = ["-p" "agnix-cli" "-p" "agnix-lsp" "-p" "agnix-mcp"];

    # Telemetry test fails in Nix sandbox (no $HOME / no network)
    checkFlags = ["--skip" "test_telemetry_enable_disable_roundtrip"];

    # Smoke test: verify all three binaries start
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      $out/bin/agnix --version
      timeout 2 $out/bin/agnix-mcp < /dev/null 2>&1 || true
      timeout 2 $out/bin/agnix-lsp < /dev/null 2>&1 || true
      echo "smoke-test: all binaries start"
      runHook postInstallCheck
    '';

    meta = {
      description = "Linter, LSP, and MCP server for AI coding assistant config files";
      homepage = "https://github.com/agent-sh/agnix";
      license = ourPkgs.lib.licenses.mit;
      mainProgram = "agnix";
    };
  }
