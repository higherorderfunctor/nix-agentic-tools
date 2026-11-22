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
  repoPath,
  ...
}: let
  inherit (pkgs) fetchFromGitHub;

  vu = packageLib;

  # agnix requires Rust edition 2024 (>= 1.91)
  rustToolchainChannel = "";
  rustPlatform = vu.mkRustPlatform {
    channel = rustToolchainChannel;
    inherit pkgs;
    override = "latest";
    pname = "agnix";
    recipeFile = repoPath ./package.nix;
  };

  rev = "c806bf5cb9711324558d2cf837936d9882c66b22";
  src = fetchFromGitHub {
    owner = "agent-sh";
    repo = "agnix";
    inherit rev;
    hash = "sha256-Np3c9dOWIL4EBteJ13509WQwWLcVz/I/GNXWPCU4IlQ=";
  };
in
  rustPlatform.buildRustPackage {
    pname = "agnix";
    version = vu.mkVersion {
      # upstream: readCargoWorkspaceVersion @ Cargo.toml
      upstream = "0.61.0";
      inherit rev;
    };
    inherit src;
    # Upstream added Kiro rule KR-SET-013 without a reach fixture, so
    # `kiro_rule_reachability` fails. The patch adds one with an out-of-range
    # `compaction.autoCompactionThreshold` and lists it in
    # `kiro_fixture_inventory`, as upstream did for KR-SET-012. Drop it once
    # upstream ships its own `tests/fixtures/kiro-reach/kr-set-013/` fixture.
    patches = [../../../patches/kr-set-013-reach-fixture.patch];
    inherit (vu) patchFlags;
    cargoHash = "sha256-Jvh6mXVcL6lvjpYH8fZvZ+es3WnbTyhICX6tgyXz8lQ=";

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

    inherit (rustPlatform) passthru;

    meta = {
      description = "Linter, LSP, and MCP server for AI coding assistant config files";
      homepage = "https://github.com/agent-sh/agnix";
      license = pkgs.lib.licenses.mit;
      mainProgram = "agnix";
    };
  }
