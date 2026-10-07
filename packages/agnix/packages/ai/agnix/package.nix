# agnix overlay — linter, LSP, and MCP server for AI coding
# assistant config files (`.agnix.toml`, `CLAUDE.md`, `AGENTS.md`,
# `SKILL.md`, hooks, MCP configs, Cursor rules, etc.).
#
# NOT a git tool — it parses AI agent config formats. Lives in its
# own `packages/agnix/` directory because it's a multi-purpose
# tool (linter + LSP + MCP server) that doesn't fit cleanly into
# git-tools or mcp-servers groupings.
#
# Argument shape adapted from legacy 2-layer curried pattern during Milestone 6 port.
{
  pkgs,
  packageLib,
  ...
}: let
  inherit (pkgs) fetchFromGitHub;

  vu = packageLib;

  # agnix requires Rust edition 2024 (>= 1.91)
  rustPlatform = vu.mkRustPlatform {inherit pkgs;};

  rev = "fa3ba366d1580a44aebea3b6e211d061ad9d8df4";
  src = fetchFromGitHub {
    owner = "agent-sh";
    repo = "agnix";
    inherit rev;
    hash = "sha256-SP9OsJsl8X5kkFrgXT9oEZfgK2jd1MGDkoyzbCfG1d0=";
  };
in
  rustPlatform.buildRustPackage {
    pname = "agnix";
    version = vu.mkVersion {
      # upstream: readCargoWorkspaceVersion @ Cargo.toml
      upstream = "0.56.6";
      inherit rev;
    };
    inherit src;
    cargoHash = "sha256-YS5zYyUnpN8L8e6dc69A8MyqlsvqwkEqD/tTQsFKzh4=";

    nativeBuildInputs = [pkgs.pkg-config];
    buildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
      pkgs.apple-sdk_15
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
      license = pkgs.lib.licenses.mit;
      mainProgram = "agnix";
    };
  }
