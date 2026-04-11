# nix-update Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace nvfetcher + custom hash/lockfile scripts with nix-update. Every overlay file becomes self-contained with inline hashes. One tool updates everything.

**Architecture:** Each overlay .nix file owns its own `fetchFromGitHub`/`fetchurl` call with inline version, source hash, and dep hashes. `passthru.updateScript` enables `nix-update --flake <pkg>` to update everything atomically. `overlays/default.nix` becomes pure grouping. nvfetcher, hashes.json, and custom scripts are deleted.

**Tech Stack:** nix-update, nix-fast-build, cachix, GitHub Actions

---

### Task 1: Pilot — migrate sympy-mcp and verify nix-update works

Simplest package: Python, no dep hashes, no nixpkgs override, no lockfiles.

**Files:**
- Modify: `overlays/mcp-servers/sympy-mcp.nix`
- Modify: `overlays/default.nix` (remove nv reference for this package)

- [ ] **Step 1: Rewrite sympy-mcp.nix with inline fetcher**

Replace the `nv`-based source with inline `fetchFromGitHub`. Current values from `generated.nix`:

```nix
# sympy-mcp — SymPy MCP server.
#
# Wraps a Python environment with sympy + mcp dependencies.
# Uses writeShellApplication to invoke mcp run on server.py.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchFromGitHub python314Packages writeShellApplication;

  version = "unstable-2026-03-18";
  src = fetchFromGitHub {
    owner = "sdiehl";
    repo = "sympy-mcp";
    rev = "646c69558b622ab0e2814c58aa82143e56b76c33";
    hash = "sha256-AjRdiBtsF/ZpAUt+TPhvkT8VQ3y7rcJSogSSyQQXytI=";
  };

  pythonEnv = python314Packages.python.withPackages (ps:
    with ps; [
      mcp
      typer
      python-dotenv
      sympy
    ]);
in
  writeShellApplication {
    name = "sympy-mcp";
    runtimeInputs = [pythonEnv];
    text = ''
      exec ${pythonEnv}/bin/python -m mcp run ${src}/server.py "$@"
    '';
    meta.mainProgram = "sympy-mcp";
  }
```

- [ ] **Step 2: Update overlays/default.nix call site**

Change the import to stop passing `nv`:

```nix
# Before:
sympy-mcp = import ./mcp-servers/sympy-mcp.nix {
  inherit inputs final;
  nv = nv.sympy-mcp;
};
# After:
sympy-mcp = import ./mcp-servers/sympy-mcp.nix {
  inherit inputs final;
};
```

- [ ] **Step 3: Verify build**

```bash
nix build .#sympy-mcp --no-link -L
```

Expected: builds successfully using inline source.

- [ ] **Step 4: Verify nix-update can manage it**

```bash
nix run nixpkgs#nix-update -- --flake sympy-mcp --version skip
```

Expected: nix-update finds the .nix file, reports "no update" or updates hashes if source changed. This validates that `nix-update --flake` works with our overlay structure.

- [ ] **Step 5: Test nix-update version bump**

```bash
nix run nixpkgs#nix-update -- --flake sympy-mcp
```

Expected: nix-update checks GitHub for latest commit, updates rev + hash if there's a newer commit. If already latest, reports "already up to date".

- [ ] **Step 6: Commit**

```bash
git add overlays/mcp-servers/sympy-mcp.nix overlays/default.nix
git commit -m "refactor(overlays): migrate sympy-mcp to inline hashes

Pilot for nix-update migration. Replaces nvfetcher nv blob with
inline fetchFromGitHub. nix-update --flake sympy-mcp now works."
```

---

### Task 2: Migrate standalone Python packages (kagi-mcp, kiro-gateway)

Same pattern as sympy-mcp but with more build complexity.

**Files:**
- Modify: `overlays/mcp-servers/kagi-mcp.nix`
- Modify: `overlays/kiro-gateway.nix`
- Modify: `overlays/default.nix`

- [ ] **Step 1: Rewrite kagi-mcp.nix**

kagi-mcp has a companion kagiapi package (currently also from nvfetcher). Both become inline:

```nix
# kagi-mcp — Kagi search MCP server.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchFromGitHub fetchurl python314Packages;

  kagiapi = python314Packages.buildPythonPackage {
    pname = "kagiapi";
    version = "0.2.1";
    src = fetchurl {
      url = "https://pypi.org/packages/source/k/kagiapi/kagiapi-0.2.1.tar.gz";
      hash = "sha256-NV/kB7TGg9bwhIJ+T4VP2VE03yhC8V0Inaz/Yg4/Sus=";
    };
    pyproject = true;
    build-system = with python314Packages; [setuptools];
    dependencies = with python314Packages; [requests];
    doCheck = false;
  };
in
  python314Packages.buildPythonApplication {
    pname = "kagi-mcp";
    version = "unstable-2026-04-08";
    src = fetchFromGitHub {
      owner = "kagisearch";
      repo = "kagimcp";
      rev = "933e3384e9b1f34ebcc84b85310be7a6548900db";
      hash = "sha256-jTxmn6H0SPV/vwDW+4tQiTXceVJZwwVgLXsF9bjSPS8=";
    };
    pyproject = true;
    build-system = with python314Packages; [hatchling];
    dependencies = with python314Packages; [kagiapi mcp pydantic];
    meta.mainProgram = "kagimcp";
    doCheck = false;
  }
```

- [ ] **Step 2: Rewrite kiro-gateway.nix**

```nix
# kiro-gateway — Python proxy API for Kiro IDE & CLI.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchFromGitHub makeWrapper python314Packages;
  python = python314Packages.python.withPackages (ps:
    with ps; [
      fastapi
      httpx
      loguru
      python-dotenv
      tiktoken
      uvicorn
    ]);
in
  ourPkgs.stdenvNoCC.mkDerivation {
    pname = "kiro-gateway";
    version = "unstable-2026-02-12";
    src = fetchFromGitHub {
      owner = "jwadow";
      repo = "kiro-gateway";
      rev = "e6f23c22fc5e9aa7a22e4c31af56cdc6f859afbd";
      hash = "sha256-V9sS82Jwx5y03ojNueHr+0qfp87fkACrdr7iP78Yxeo=";
    };
    dontBuild = true;
    nativeBuildInputs = [makeWrapper];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/kiro-gateway $out/bin
      cp -r . $out/lib/kiro-gateway/
      makeWrapper ${python}/bin/python $out/bin/kiro-gateway \
        --add-flags "$out/lib/kiro-gateway/main.py"
      runHook postInstall
    '';
    meta.mainProgram = "kiro-gateway";
  }
```

- [ ] **Step 3: Update overlays/default.nix call sites**

Remove `nv` from both imports. Also remove the `kiro-gateway` and `kagi-mcp` entries from the `nv` map.

- [ ] **Step 4: Verify builds**

```bash
nix build .#kagi-mcp .#kiro-gateway --no-link -L
```

- [ ] **Step 5: Verify nix-update**

```bash
nix run nixpkgs#nix-update -- --flake kagi-mcp --version skip
nix run nixpkgs#nix-update -- --flake kiro-gateway --version skip
```

- [ ] **Step 6: Commit**

```bash
git add overlays/mcp-servers/kagi-mcp.nix overlays/kiro-gateway.nix overlays/default.nix
git commit -m "refactor(overlays): migrate kagi-mcp, kiro-gateway to inline hashes"
```

---

### Task 3: Migrate nixpkgs-override Python packages (git-revise, mcp-proxy)

These override existing nixpkgs packages. The override still happens but version/src/hash are inline.

**Files:**
- Modify: `overlays/git-tools/git-revise.nix`
- Modify: `overlays/mcp-servers/mcp-proxy.nix`
- Modify: `overlays/default.nix`

- [ ] **Step 1: Rewrite git-revise.nix**

```nix
# git-revise — override nixpkgs with nightly version.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchFromGitHub;
in
  ourPkgs.git-revise.overrideAttrs (_old: {
    version = "unstable-2026-03-02";
    src = fetchFromGitHub {
      owner = "mystor";
      repo = "git-revise";
      rev = "a5bdbe420521a7784dd16c8f22b374b2f1d2d167";
      hash = "sha256-D3MicmtruCNiW/WI37y18XDXAl7J9oJdJnDY4Ohj+rE=";
    };
    pyproject = true;
    build-system = with ourPkgs.python314Packages; [hatchling];
    postPatch = null;
    nativeCheckInputs = (ourPkgs.git-revise.nativeCheckInputs or []) ++ [ourPkgs.openssh];
  })
```

- [ ] **Step 2: Rewrite mcp-proxy.nix**

```nix
# mcp-proxy — override nixpkgs with nightly version.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchFromGitHub;
in
  ourPkgs.mcp-proxy.overrideAttrs (finalAttrs: _old: {
    version = "unstable-2026-03-14";
    src = fetchFromGitHub {
      owner = "sparfenyuk";
      repo = "mcp-proxy";
      rev = "a6720cc4f0bb3a09748d61207fb33f3c7c8a88e4";
      hash = "sha256-Sx0YrCwTCV8wGmwzJPiEhOkHy4CcaKW4mtnLntE7qYU=";
    };
    dependencies =
      (ourPkgs.mcp-proxy.dependencies or [])
      ++ [ourPkgs.python314Packages.httpx-auth];
    doCheck = false;
  })
```

- [ ] **Step 3: Update default.nix, verify builds + nix-update**

```bash
nix build .#git-revise .#mcp-proxy --no-link -L
nix run nixpkgs#nix-update -- --flake git-revise --version skip
nix run nixpkgs#nix-update -- --flake mcp-proxy --version skip
```

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor(overlays): migrate git-revise, mcp-proxy to inline hashes"
```

---

### Task 4: Migrate pre-built binaries (any-buddy, copilot-cli, kiro-cli)

No dep hashes. Pre-built binaries just need version + source hash. Exotic version sources get custom `passthru.updateScript`.

**Files:**
- Modify: `overlays/any-buddy.nix`
- Modify: `overlays/copilot-cli.nix`
- Modify: `overlays/kiro-cli.nix`
- Modify: `overlays/default.nix`

- [ ] **Step 1: Rewrite any-buddy.nix**

```nix
# any-buddy — buddy salt search worker (source-only, runs via Bun).
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchFromGitHub;
in
  ourPkgs.stdenvNoCC.mkDerivation {
    pname = "any-buddy";
    version = "unstable-2026-04-06";
    src = fetchFromGitHub {
      owner = "cpaczek";
      repo = "any-buddy";
      rev = "861f0dfea1674dcff9a72390143fc64d026c95ed";
      hash = "sha256-nkAeA2MuBmiDcBjIGzIbfxt0nvkHC++OSD+OWWwQ/e0=";
    };
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/any-buddy
      cp -r . $out/lib/any-buddy/
      runHook postInstall
    '';
  }
```

- [ ] **Step 2: Rewrite copilot-cli.nix with per-platform inline sources**

```nix
# copilot-cli — GitHub Copilot CLI pre-built binary.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) autoPatchelfHook fetchurl stdenv;

  version = "1.0.22";
  platformSrc = {
    "x86_64-linux" = fetchurl {
      url = "https://github.com/github/copilot-cli/releases/download/v${version}/copilot-linux-x64.tar.gz";
      hash = "sha256-2h40sQXtHPpftSz0MQg98PVW078PLMyPmZ+wwAMxQIE=";
    };
    "aarch64-darwin" = fetchurl {
      url = "https://github.com/github/copilot-cli/releases/download/v${version}/copilot-darwin-arm64.tar.gz";
      hash = "sha256-uIuUUmwxWe9yt/4Eh9h2OXVwb5+QfWeWe0XvXVIBpu4=";
    };
  };
in
  stdenv.mkDerivation {
    pname = "copilot-cli";
    inherit version;
    src = platformSrc.${stdenv.hostPlatform.system};
    sourceRoot = ".";
    nativeBuildInputs = ourPkgs.lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      install -Dm755 copilot $out/bin/copilot
      runHook postInstall
    '';
    meta = {
      mainProgram = "copilot";
      license = ourPkgs.lib.licenses.unfree;
    };
  }
```

- [ ] **Step 3: Rewrite kiro-cli.nix with per-platform inline sources and custom updateScript**

```nix
# kiro-cli — Kiro CLI pre-built binary from AWS.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchurl makeWrapper stdenv writeShellScript;

  version = "1.29.6";
  platformSrc = {
    "x86_64-linux" = fetchurl {
      url = "https://desktop-release.q.us-east-1.amazonaws.com/${version}/kirocli-x86_64-linux.tar.gz";
      hash = "sha256-6FZgHdKBDz8zrrJf0MgGtzKz279j4X3H/B6tW+0WlZ8=";
    };
    "aarch64-darwin" = fetchurl {
      url = "https://desktop-release.q.us-east-1.amazonaws.com/${version}/Kiro%20CLI.dmg";
      name = "kiro-cli.dmg";
      hash = "sha256-qe9svpw3ngk9EU12woeMXW8+gTNYxGfzdePVUgodUWY=";
    };
  };
in
  stdenv.mkDerivation {
    pname = "kiro-cli";
    inherit version;
    src = platformSrc.${stdenv.hostPlatform.system};
    sourceRoot = ".";
    nativeBuildInputs = [makeWrapper]
      ++ ourPkgs.lib.optionals stdenv.hostPlatform.isDarwin [ourPkgs.undmg];
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      install -Dm755 kiro-cli $out/bin/kiro-cli
      install -Dm755 kiro-cli-chat $out/bin/kiro-cli-chat
      wrapProgram $out/bin/kiro-cli --set TERM xterm-256color
      wrapProgram $out/bin/kiro-cli-chat --set TERM xterm-256color
      runHook postInstall
    '';
    passthru.updateScript = writeShellScript "update-kiro-cli" ''
      set -eu
      version=$(${ourPkgs.curl}/bin/curl -s https://desktop-release.q.us-east-1.amazonaws.com/latest/manifest.json | ${ourPkgs.jq}/bin/jq -r '.version')
      update-source-version kiro-cli "$version" --ignore-same-version
    '';
    meta = {
      mainProgram = "kiro-cli";
      license = ourPkgs.lib.licenses.unfree;
    };
  }
```

- [ ] **Step 4: Update default.nix, verify builds**

```bash
nix build .#any-buddy .#copilot-cli .#kiro-cli --no-link -L
```

- [ ] **Step 5: Commit**

```bash
git commit -m "refactor(overlays): migrate any-buddy, copilot-cli, kiro-cli to inline hashes"
```

---

### Task 5: Migrate Rust packages (agnix, git-absorb, git-branchless)

These have `cargoHash` dep hashes that nix-update handles natively.

**Files:**
- Modify: `overlays/agnix.nix`
- Modify: `overlays/git-tools/git-absorb.nix`
- Modify: `overlays/git-tools/git-branchless.nix`
- Modify: `overlays/default.nix`

- [ ] **Step 1: Rewrite agnix.nix**

Replace `inherit (nv) version src; cargoHash = nv.cargoHash;` with inline values. Keep the Rust toolchain logic and three-binary build. Current cargoHash from hashes.json: `sha256-wlKyY26kryzhoARuh/FY7+NF3dfip4NiZOK8MtDDveI=`.

The key change is in the arguments (drop `nv`) and the source:

```nix
# Before (in the let block):
#   inherit (nv) version src;
#   cargoHash = nv.cargoHash;
# After:
  version = "unstable-2026-04-10";
  src = fetchFromGitHub {
    owner = "agent-sh";
    repo = "agnix";
    rev = "2c8f259f036660c477a420ff9ba7260116a78451";
    hash = "sha256-LV9/pII/Ffap9w+SBR7Pf/lMfePCyokL8hIzdD63tyk=";
  };
  cargoHash = "sha256-wlKyY26kryzhoARuh/FY7+NF3dfip4NiZOK8MtDDveI=";
```

Add `fetchFromGitHub` to the inherit. Remove `nv` from function args.

- [ ] **Step 2: Rewrite git-absorb.nix**

Same pattern. Override nixpkgs git-absorb with inline src + cargoHash. Current cargoHash: `sha256-8uCXk5bXn/x4QXbGOROGlWYMSqIv+/7dBGZKbYkLfF4=`.

```nix
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchFromGitHub;
  rust = inputs.rust-overlay.packages.${final.stdenv.hostPlatform.system}.rust;
in
  (ourPkgs.git-absorb.override {
    rustPlatform = ourPkgs.makeRustPlatform {
      cargo = rust;
      rustc = rust;
    };
  }).overrideAttrs (finalAttrs: _old: {
    version = "unstable-2026-02-13";
    src = fetchFromGitHub {
      owner = "tummychow";
      repo = "git-absorb";
      rev = "debdcd28d9db2ac6b36205bda307b6693a6a91e7";
      hash = "sha256-jAR+Vq6SZZXkseOxZVJSjsQOStIip8ThiaLroaJcIfc=";
    };
    cargoDeps = ourPkgs.rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) pname version src;
      hash = "sha256-8uCXk5bXn/x4QXbGOROGlWYMSqIv+/7dBGZKbYkLfF4=";
    };
  })
```

- [ ] **Step 3: Rewrite git-branchless.nix**

Same pattern. Note: pins Rust 1.88.0 (workaround). Current cargoHash: `sha256-vLm/RuOc7K0YRvFvrA356OmcmLYzdpBjETsSCn+KyT4=`. Version check fails (pre-existing issue — commit hash vs 0.10.0).

```nix
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchFromGitHub;
  rust = inputs.rust-overlay.packages.${final.stdenv.hostPlatform.system}.rust_1_88_0;
in
  (ourPkgs.git-branchless.override {
    rustPlatform = ourPkgs.makeRustPlatform {
      cargo = rust;
      rustc = rust;
    };
  }).overrideAttrs (finalAttrs: _old: {
    version = "unstable-2026-03-01";
    src = fetchFromGitHub {
      owner = "arxanas";
      repo = "git-branchless";
      rev = "f238c0993fea69700b56869b3ee9fd03178c6e32";
      hash = "sha256-ar2168yI3OgNMwqrzilKK9QORKbe1QtHVe88JkS7EOs=";
    };
    cargoDeps = ourPkgs.rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) pname version src;
      hash = "sha256-vLm/RuOc7K0YRvFvrA356OmcmLYzdpBjETsSCn+KyT4=";
    };
    postPatch = null;
    doInstallCheck = false;
  })
```

- [ ] **Step 4: Update default.nix, verify builds + nix-update**

```bash
nix build .#agnix .#git-absorb --no-link -L
nix run nixpkgs#nix-update -- --flake agnix --version skip
nix run nixpkgs#nix-update -- --flake git-absorb --version skip
```

Note: git-branchless may fail its version check. Build with `--no-link` to verify compilation succeeds.

- [ ] **Step 5: Commit**

```bash
git commit -m "refactor(overlays): migrate agnix, git-absorb, git-branchless to inline hashes"
```

---

### Task 6: Migrate Go packages (github-mcp, mcp-language-server)

These override nixpkgs Go packages. `vendorHash` is the dep hash.

**Files:**
- Modify: `overlays/mcp-servers/github-mcp.nix`
- Modify: `overlays/mcp-servers/mcp-language-server.nix`
- Modify: `overlays/default.nix`

- [ ] **Step 1: Rewrite github-mcp.nix**

```nix
# github-mcp — override nixpkgs github-mcp-server with nightly.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchFromGitHub;
in
  ourPkgs.github-mcp-server.overrideAttrs (finalAttrs: _old: {
    version = "0.32.0";
    src = fetchFromGitHub {
      owner = "github";
      repo = "github-mcp-server";
      rev = "v${finalAttrs.version}";
      hash = "sha256-BD/t3UBAvrzJpRI7b06FjE8c+vzdQiXsj6eiUGQX6uA=";
    };
    vendorHash = "sha256-q21hnMnWOzfg7BGDl4KM1I3v0wwS5sSxzLA++L6jO4s=";
  })
```

- [ ] **Step 2: Rewrite mcp-language-server.nix**

```nix
# mcp-language-server — override nixpkgs with nightly.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchFromGitHub;
in
  ourPkgs.mcp-language-server.overrideAttrs (finalAttrs: _old: {
    version = "unstable-2025-06-03";
    src = fetchFromGitHub {
      owner = "isaacphi";
      repo = "mcp-language-server";
      rev = "e4395849a52e18555361abab60a060802c06bf50";
      hash = "sha256-INyzT/8UyJfg1PW5+PqZkIy/MZrDYykql0rD2Sl97Gg=";
    };
    vendorHash = "sha256-5YUI1IujtJJBfxsT9KZVVFVib1cK/Alk73y5tqxi6pQ=";
  })
```

- [ ] **Step 3: Update default.nix, verify builds + nix-update**

```bash
nix build .#github-mcp .#mcp-language-server --no-link -L
nix run nixpkgs#nix-update -- --flake github-mcp --version skip
```

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor(overlays): migrate github-mcp, mcp-language-server to inline hashes"
```

---

### Task 7: Migrate npm packages (claude-code, git-intel-mcp, openmemory-mcp)

These use `buildNpmPackage` with `npmDepsHash`. nix-update handles npmDepsHash + lockfile generation natively.

**Files:**
- Modify: `overlays/claude-code.nix`
- Modify: `overlays/mcp-servers/git-intel-mcp.nix`
- Modify: `overlays/mcp-servers/openmemory-mcp.nix`
- Modify: `overlays/default.nix`

- [ ] **Step 1: Rewrite claude-code.nix**

Claude-code uses a custom updateScript (npm registry source). Replace `inherit (nv) version src; npmDepsHash = nv.npmDepsHash;` with inline values. Keep the buildNpmPackage override and buddy wrapper logic. The lockfile moves from `locks/claude-code-package-lock.json` to being managed by nix-update's `--generate-lockfile`.

Key changes to the let block:

```nix
  version = "2.1.100";
  src = fetchurl {
    url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${version}.tgz";
    hash = "sha256-Dkip2mnbcvks8SbZVBqXajaRi1SQEemN2IDiHxlaqbA=";
  };
  npmDepsHash = "sha256-5LvH7fG5pti2SiXHQqgRxfFpxaXxzrmGxIoPR4dGE+8=";
```

Add `passthru.updateScript` for npm registry version check:

```nix
passthru.updateScript = writeShellScript "update-claude-code" ''
  set -eu
  version=$(${ourPkgs.curl}/bin/curl -s https://registry.npmjs.org/@anthropic-ai/claude-code/latest | ${ourPkgs.jq}/bin/jq -r .version)
  update-source-version claude-code "$version" --ignore-same-version
'';
```

Note: the lockfile path reference in the overlay needs updating. With nix-update managing lockfiles, the lockfile should live alongside the .nix file or at a path nix-update can find. Verify with `nix-update --flake claude-code --generate-lockfile` after migration.

- [ ] **Step 2: Rewrite git-intel-mcp.nix**

```nix
# git-intel-mcp — Git Intel MCP server.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) buildNpmPackage fetchgit makeWrapper nodejs;
in
  buildNpmPackage {
    pname = "git-intel-mcp";
    version = "unstable-2026-03-18";
    src = fetchgit {
      url = "https://github.com/hoangsonww/GitIntel-MCP-Server.git";
      rev = "9f216bab8d6bc3a3b850ad77f27d02d63a71e10d";
      hash = "sha256-UCIUmU6slN9EjL8Bf2JKfvyoVKE0jgUsfLd8OocdwNc=";
    };
    npmDepsHash = "sha256-/HN6Ylrow/v7ssWb0oIYJD5cTV8RWH8ipmDtfAUY9zc=";
    npmBuildScript = "build";
    nativeBuildInputs = [makeWrapper];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/git-intel-mcp $out/bin
      cp -r dist node_modules package.json $out/lib/git-intel-mcp/
      makeWrapper ${nodejs}/bin/node $out/bin/git-intel-mcp \
        --add-flags "$out/lib/git-intel-mcp/dist/index.js"
      runHook postInstall
    '';
    meta.mainProgram = "git-intel-mcp";
  }
```

- [ ] **Step 3: Rewrite openmemory-mcp.nix**

```nix
# openmemory-mcp — OpenMemory MCP server.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) buildNpmPackage fetchFromGitHub makeWrapper nodejs;

  version = "unstable-2026-04-08";
  src = fetchFromGitHub {
    owner = "CaviraOSS";
    repo = "OpenMemory";
    rev = "a65c920636b1b39618e833f1a0f8494aebccafcd";
    hash = "sha256-cXbftztatmbYPv4uYh3YVpXS65yHzs+D6EOR5Y7x9rw=";
  };

  packageJson = builtins.fromJSON (builtins.readFile "${src}/packages/openmemory-js/package.json");
in
  buildNpmPackage {
    pname = "openmemory-mcp";
    inherit version;
    inherit src;
    sourceRoot = "source/packages/openmemory-js";
    postUnpack = "chmod -R u+w source";
    npmDepsHash = "sha256-jHs7NOn85SFoEeqcTxxftKyf/3dG1OWgOmrMHEdfnGM=";
    npmBuildScript = "build";
    nativeBuildInputs = [makeWrapper];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/openmemory-mcp $out/bin
      cp -r bin dist node_modules package.json $out/lib/openmemory-mcp/
      makeWrapper ${nodejs}/bin/node $out/bin/openmemory-mcp \
        --add-flags "$out/lib/openmemory-mcp/dist/index.js"
      makeWrapper ${nodejs}/bin/node $out/bin/openmemory-mcp-serve \
        --add-flags "$out/lib/openmemory-mcp/dist/serve.js"
      runHook postInstall
    '';
    meta.mainProgram = "openmemory-mcp";
  }
```

- [ ] **Step 4: Update default.nix, verify builds**

```bash
nix build .#claude-code .#git-intel-mcp .#openmemory-mcp --no-link -L
nix run nixpkgs#nix-update -- --flake git-intel-mcp --version skip
```

- [ ] **Step 5: Commit**

```bash
git commit -m "refactor(overlays): migrate claude-code, git-intel-mcp, openmemory-mcp to inline hashes"
```

---

### Task 8: Migrate pnpm packages (context7-mcp, effect-mcp)

These use `pnpmDepsHash`. context7-mcp overrides nixpkgs. effect-mcp builds from scratch with pnpmConfigHook.

**Files:**
- Modify: `overlays/mcp-servers/context7-mcp.nix`
- Modify: `overlays/mcp-servers/effect-mcp.nix`
- Modify: `overlays/default.nix`

- [ ] **Step 1: Rewrite context7-mcp.nix**

```nix
# context7-mcp — override nixpkgs with nightly.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchurl;

  version = "2.1.7";
  src = ourPkgs.runCommandLocal "context7-mcp-src-${version}" {} ''
    tar xf ${fetchurl {
      url = "https://github.com/upstash/context7/archive/refs/tags/@upstash/context7-mcp@${version}.tar.gz";
      name = "context7-mcp-${version}.tar.gz";
      hash = "sha256-0l42zdVNiyAQei9Fl29xNLBl74u74UA4zf7jZzsB7ME=";
    }}
    mv context7-* $out
  '';
in
  ourPkgs.context7-mcp.overrideAttrs (finalAttrs: _old: {
    inherit src version;
    pnpmDeps = ourPkgs.fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      fetcherVersion = 3;
      hash = "sha256-8RRHfCTZVC91T1Qx+ACCo2oG4ZwMNy5WYakCjmBhe3Q=";
    };
  })
```

Note: context7-mcp has a scoped GitHub tag. Custom updateScript needed if we want nix-update to check versions:

```nix
passthru.updateScript = writeShellScript "update-context7-mcp" ''
  set -eu
  version=$(${ourPkgs.curl}/bin/curl -sL "https://api.github.com/repos/upstash/context7/tags?per_page=100" |
    ${ourPkgs.jq}/bin/jq -r '[.[] | select(.name | test("^@upstash/context7-mcp@[0-9]"))][0].name' |
    sed 's/^@upstash\/context7-mcp@//')
  update-source-version context7-mcp "$version" --ignore-same-version
'';
```

- [ ] **Step 2: Rewrite effect-mcp.nix**

```nix
# effect-mcp — Effect MCP server built via pnpm + tsup.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchFromGitHub fetchPnpmDeps makeWrapper nodejs pnpm pnpmConfigHook;
in
  ourPkgs.stdenv.mkDerivation (finalAttrs: {
    pname = "effect-mcp";
    version = "unstable-2026-02-24";
    src = fetchFromGitHub {
      owner = "tim-smart";
      repo = "effect-mcp";
      rev = "83a768303839b9e125f6c286369a5d9cc26c666e";
      hash = "sha256-okTpUZnYUfIuZThnqDKJ+FGImIeRLY2DMiS6HEQBoTQ=";
    };
    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      fetcherVersion = 3;
      hash = "sha256-8VCbs1gEKWGUD7nKxDL48RErzY0KW5k4fcW+chnAJ70=";
    };
    nativeBuildInputs = [makeWrapper nodejs pnpm pnpmConfigHook];
    buildPhase = ''
      runHook preBuild
      pnpm build
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/effect-mcp $out/bin
      cp -r dist/* $out/lib/effect-mcp/
      makeWrapper ${nodejs}/bin/node $out/bin/effect-mcp \
        --add-flags "$out/lib/effect-mcp/main.cjs"
      runHook postInstall
    '';
    meta.mainProgram = "effect-mcp";
  })
```

- [ ] **Step 3: Update default.nix, verify builds**

```bash
nix build .#context7-mcp .#effect-mcp --no-link -L
nix run nixpkgs#nix-update -- --flake effect-mcp --version skip
```

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor(overlays): migrate context7-mcp, effect-mcp to inline hashes"
```

---

### Task 9: Restructure modelcontextprotocol mono-repo

Replace single file with directory of parallel-friendly derivations.

**Files:**
- Delete: `overlays/mcp-servers/modelcontextprotocol-servers.nix`
- Create: `overlays/mcp-servers/modelcontextprotocol/default.nix`
- Create: `overlays/mcp-servers/modelcontextprotocol/js-build.nix`
- Modify: `overlays/default.nix`

- [ ] **Step 1: Create js-build.nix — single pnpm derivation for all JS servers**

```nix
# Builds all JS packages from the modelcontextprotocol/servers mono-repo
# using the shared pnpm-lock.yaml. Each server ends up under
# $out/servers/{name}/dist/.
{
  ourPkgs,
  version,
  src,
}: let
  inherit (ourPkgs) fetchPnpmDeps nodejs pnpm pnpmConfigHook;
in
  ourPkgs.stdenv.mkDerivation (finalAttrs: {
    pname = "modelcontextprotocol-js-servers";
    inherit version src;
    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      fetcherVersion = 3;
      hash = ""; # nix-update will fill this
    };
    nativeBuildInputs = [nodejs pnpm pnpmConfigHook];
    buildPhase = ''
      runHook preBuild
      pnpm --filter './src/sequentialthinking' build
      pnpm --filter './src/filesystem' build
      pnpm --filter './src/memory' build
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/servers
      for dir in sequentialthinking filesystem memory; do
        cp -r src/$dir $out/servers/$dir
      done
      runHook postInstall
    '';
  })
```

Note: the pnpmDeps hash starts empty — run `nix build .#mcp-sequential-thinking` to trigger hash computation, then nix-update fills it.

- [ ] **Step 2: Create default.nix — directory entry point**

```nix
# modelcontextprotocol/servers — mono-repo with JS + Python servers.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchFromGitHub makeWrapper nodejs python314Packages;

  version = "unstable-2026-03-17";
  src = fetchFromGitHub {
    owner = "modelcontextprotocol";
    repo = "servers";
    rev = "f4244583a6af9425633e433a3eec000d23f4e011";
    hash = "sha256-bHknioQu8i5RcFlBBdXUQjsV4WN1IScnwohGRxXgGDk=";
  };

  jsBuild = import ./js-build.nix {inherit ourPkgs version src;};

  mkJsWrapper = name: subdir:
    ourPkgs.stdenvNoCC.mkDerivation {
      pname = name;
      inherit version;
      dontUnpack = true;
      nativeBuildInputs = [makeWrapper];
      installPhase = ''
        mkdir -p $out/bin
        makeWrapper ${nodejs}/bin/node $out/bin/${name} \
          --add-flags "${jsBuild}/servers/${subdir}/dist/index.js"
      '';
      meta.mainProgram = name;
    };

  readPyVersion = subdir: let
    content = builtins.readFile "${src}/src/${subdir}/pyproject.toml";
    lines = builtins.filter (l: builtins.isString l && l != "") (builtins.split "\n" content);
    vLine = builtins.head (builtins.filter (l: builtins.match "^version = .*" l != null) lines);
  in
    builtins.head (builtins.match "^version = \"(.*)\"$" vLine);
in {
  # JS servers — lightweight wrappers around shared build
  sequential-thinking = mkJsWrapper "mcp-sequential-thinking" "sequentialthinking";
  filesystem = mkJsWrapper "mcp-filesystem" "filesystem";
  memory = mkJsWrapper "mcp-memory" "memory";

  # Python servers — independent builds
  fetch = python314Packages.buildPythonApplication {
    pname = "mcp-fetch";
    version = readPyVersion "fetch";
    src = "${src}/src/fetch";
    pyproject = true;
    build-system = with python314Packages; [hatchling];
    dependencies = with python314Packages; [
      httpx markdownify mcp protego pydantic readabilipy requests
    ];
    pythonRelaxDeps = ["httpx"];
    meta.mainProgram = "mcp-server-fetch";
    doCheck = false;
  };

  git = python314Packages.buildPythonApplication {
    pname = "mcp-git";
    version = readPyVersion "git";
    src = "${src}/src/git";
    pyproject = true;
    build-system = with python314Packages; [hatchling];
    dependencies = with python314Packages; [click gitpython mcp pydantic];
    meta.mainProgram = "mcp-server-git";
    doCheck = false;
  };

  time = python314Packages.buildPythonApplication {
    pname = "mcp-time";
    version = readPyVersion "time";
    src = "${src}/src/time";
    pyproject = true;
    build-system = with python314Packages; [hatchling];
    dependencies = with python314Packages; [mcp pydantic tzdata tzlocal];
    meta.mainProgram = "mcp-server-time";
    doCheck = false;
  };
}
```

- [ ] **Step 3: Delete old file**

```bash
rm overlays/mcp-servers/modelcontextprotocol-servers.nix
```

- [ ] **Step 4: Update overlays/default.nix**

Replace the old mono-repo import with the new directory import:

```nix
# Before:
mcpMonoRepoDrvs = import ./mcp-servers/modelcontextprotocol-servers.nix {
  inherit inputs final hashes dummyHash;
  nv = nv.mcp-servers-mono;
};
# After:
modelContextProtocol = import ./mcp-servers/modelcontextprotocol {
  inherit inputs final;
};
```

And update the mcpServerDrvs to include the namespaced mono-repo:

```nix
mcpServerDrvs = {
  # standalone servers ...
  inherit modelContextProtocol;
} // modelContextProtocol; # also flatten for backward compat
```

Note: the flattening is temporary for backward compatibility with existing flake package names. After all consumers are updated, the flat names can be removed.

- [ ] **Step 5: Build and verify**

```bash
nix build .#mcp-sequential-thinking .#mcp-fetch .#mcp-git --no-link -L
```

Note: the pnpmDeps hash will need computing on first build. Let nix report the correct hash, update `js-build.nix`, rebuild.

- [ ] **Step 6: Commit**

```bash
git commit -m "refactor(overlays): restructure modelcontextprotocol mono-repo

Single pnpm build for JS servers with lightweight wrappers.
Independent Python builds. Namespaced under modelContextProtocol."
```

---

### Task 10: Clean up overlays/default.nix

Remove all nvfetcher machinery now that all packages are migrated.

**Files:**
- Modify: `overlays/default.nix`

- [ ] **Step 1: Remove nv machinery**

Delete: `hashes`, `dummyHash`, `nvSrc`, `hashDefaults`, `merge`, entire `nv` map. The file should become just:

```nix
{inputs, ...}: final: prev: let
  isUnfree = drv: let
    license = drv.meta.license or {};
  in
    if builtins.isList license
    then builtins.any (l: !(l.free or true)) license
    else !(license.free or true);

  ensureUnfreeCheck = drv:
    if isUnfree drv
    then
      final.symlinkJoin {
        inherit (drv) name version;
        paths = [drv];
        meta = drv.meta or {};
        passthru = drv.passthru or {};
      }
    else drv;

  guard = builtins.mapAttrs (_: ensureUnfreeCheck);

  flatDrvs = {
    agnix = import ./agnix.nix {inherit inputs final;};
    any-buddy = import ./any-buddy.nix {inherit inputs final;};
    claude-code = import ./claude-code.nix {inherit inputs final prev;};
    copilot-cli = import ./copilot-cli.nix {inherit inputs final;};
    kiro-cli = import ./kiro-cli.nix {inherit inputs final;};
    kiro-gateway = import ./kiro-gateway.nix {inherit inputs final;};
  };

  agnixMcp = import ./mcp-servers/agnix-mcp.nix {inherit (flatDrvs) agnix;};
  agnixLsp = import ./lsp-servers/agnix-lsp.nix {inherit (flatDrvs) agnix;};

  modelContextProtocol = import ./mcp-servers/modelcontextprotocol {inherit inputs final;};

  mcpServerDrvs =
    modelContextProtocol
    // {
      inherit modelContextProtocol;
      agnix-mcp = agnixMcp;
      context7-mcp = import ./mcp-servers/context7-mcp.nix {inherit inputs final;};
      effect-mcp = import ./mcp-servers/effect-mcp.nix {inherit inputs final;};
      git-intel-mcp = import ./mcp-servers/git-intel-mcp.nix {inherit inputs final;};
      github-mcp = import ./mcp-servers/github-mcp.nix {inherit inputs final;};
      kagi-mcp = import ./mcp-servers/kagi-mcp.nix {inherit inputs final;};
      mcp-language-server = import ./mcp-servers/mcp-language-server.nix {inherit inputs final;};
      mcp-proxy = import ./mcp-servers/mcp-proxy.nix {inherit inputs final;};
      nixos-mcp = import ./mcp-servers/nixos-mcp.nix {inherit inputs final;};
      openmemory-mcp = import ./mcp-servers/openmemory-mcp.nix {inherit inputs final;};
      serena-mcp = import ./mcp-servers/serena-mcp.nix {inherit inputs final;};
      sympy-mcp = import ./mcp-servers/sympy-mcp.nix {inherit inputs final;};
    };

  gitToolDrvs = {
    git-absorb = import ./git-tools/git-absorb.nix {inherit inputs final;};
    git-branchless = import ./git-tools/git-branchless.nix {inherit inputs final;};
    git-revise = import ./git-tools/git-revise.nix {inherit inputs final;};
  };
in {
  ai =
    guard flatDrvs
    // {
      mcpServers = guard (mcpServerDrvs // {agnix-mcp = agnixMcp;});
      lspServers = guard {agnix-lsp = agnixLsp;};
    };
  gitTools = guard gitToolDrvs;
}
```

- [ ] **Step 2: Verify full build**

```bash
nix run --inputs-from . nixpkgs#nix-fast-build -- --skip-cached --no-nom --no-link --flake ".#packages.x86_64-linux"
```

- [ ] **Step 3: Commit**

```bash
git commit -m "refactor(overlays): remove nvfetcher machinery from default.nix"
```

---

### Task 11: Delete nvfetcher infrastructure

**Files:**
- Delete: `config/nvfetcher/nvfetcher.toml`
- Delete: `overlays/sources/generated.nix`
- Delete: `overlays/sources/generated.json`
- Delete: `overlays/sources/hashes.json`
- Delete: `overlays/sources/locks/` (entire directory)
- Delete: `dev/scripts/update-hashes.sh`
- Delete: `dev/scripts/update-locks.sh`
- Modify: `flake.nix` (remove nvSourcesOverlay, remove nvfetcher from CI shell)
- Modify: `devenv.nix` (remove nv-sources overlay, remove nvfetcher from packages)
- Modify: `devenv.nix` (remove update:sources, update:locks, update:hashes tasks)

- [ ] **Step 1: Delete files**

```bash
rm -rf config/nvfetcher overlays/sources/generated.nix overlays/sources/generated.json
rm -rf overlays/sources/hashes.json overlays/sources/locks
rm dev/scripts/update-hashes.sh dev/scripts/update-locks.sh
```

- [ ] **Step 2: Update flake.nix**

Remove `nvSourcesOverlay` definition and its usage in `overlays.default`:

```nix
# Remove this:
nvSourcesOverlay = final: _prev: {
  nv-sources = import ./overlays/sources/generated.nix {
    inherit (final) fetchurl fetchgit fetchFromGitHub dockerTools;
  };
};

# In overlays.default, remove nvSourcesOverlay from composeManyExtensions:
default = lib.composeManyExtensions [
  # nvSourcesOverlay — REMOVED
  aiOverlay
  codingStandardsOverlay
  fragmentsDocsOverlay
  stackedWorkflowsOverlay
];
```

Remove `nvfetcher` from CI shell packages:

```nix
ci = pkgs.mkShell {
  name = "nix-agentic-tools-ci";
  packages = with pkgs; [
    devenv
    jq
    nodejs
    # nvfetcher — REMOVED
    prefetch-npm-deps
  ];
};
```

- [ ] **Step 3: Update devenv.nix**

Remove nv-sources overlay:

```nix
overlays = [
  # nv-sources overlay — REMOVED
  (import ./overlays {inherit inputs;})
  (import ./packages/stacked-workflows/overlay.nix {})
];
```

Remove nvfetcher from packages:

```nix
packages = with pkgs; [
  cspell
  deadnix
  mdbook
  # nvfetcher — REMOVED
  pagefind
  prefetch-npm-deps
  # ...
];
```

Remove update tasks that reference deleted scripts:

```nix
# Remove: update:sources, update:locks, update:hashes
# Keep: update:flake, update:devenv
# Replace update:all with nix-update loop
"update:all" = {
  description = "Update all packages via nix-update";
  after = ["update:flake" "update:devenv"];
  exec = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    system=$(nix eval --impure --raw --expr 'builtins.currentSystem')
    for pkg in $(nix eval ".#packages.''${system}" --apply 'builtins.attrNames' --json | jq -r '.[]' | grep -vE '^(instructions-|docs)'); do
      echo "Updating $pkg..."
      nix run nixpkgs#nix-update -- --flake "$pkg" --commit || echo "SKIP: $pkg (update failed or no change)"
    done
  '';
};
```

- [ ] **Step 4: Verify full build**

```bash
nix run --inputs-from . nixpkgs#nix-fast-build -- --skip-cached --no-nom --no-link --flake ".#packages.x86_64-linux"
```

- [ ] **Step 5: Commit**

```bash
git commit -m "refactor: delete nvfetcher infrastructure

Removed: nvfetcher.toml, generated.nix, hashes.json, lockfiles,
update-hashes.sh, update-locks.sh. nv-sources overlay dropped from
flake.nix and devenv.nix. update:all task now uses nix-update."
```

---

### Task 12: End-to-end local test

**Files:** None (verification only)

- [ ] **Step 1: Run nix-update on all packages**

```bash
system=$(nix eval --impure --raw --expr 'builtins.currentSystem')
for pkg in $(nix eval ".#packages.${system}" --apply 'builtins.attrNames' --json | jq -r '.[]' | grep -vE '^(instructions-|docs)'); do
  echo "=== $pkg ==="
  nix run nixpkgs#nix-update -- --flake "$pkg" --version skip || echo "SKIP: $pkg"
done
```

Expected: each package reports "already up to date" or updates inline.

- [ ] **Step 2: Build all packages**

```bash
nix run --inputs-from . nixpkgs#nix-fast-build -- --skip-cached --no-nom --no-link --flake ".#packages.x86_64-linux"
```

Expected: all packages build (except git-branchless version check — pre-existing).

- [ ] **Step 3: Push to cachix**

```bash
nix run --inputs-from . nixpkgs#nix-fast-build -- --skip-cached --no-nom --no-link --cachix-cache nix-agentic-tools --flake ".#packages.x86_64-linux"
```

- [ ] **Step 4: Verify nix-update version bump works**

Pick a package known to have upstream changes:

```bash
nix run nixpkgs#nix-update -- --flake effect-mcp
```

Expected: checks GitHub, updates rev + hash + pnpmDepsHash if newer commit exists.

- [ ] **Step 5: Run devenv shell**

```bash
devenv shell -- echo "devenv OK"
```

Expected: devenv evaluates without nv-sources overlay, all packages available.
