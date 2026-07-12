# kiro-memory-distiller — packages the kiro-cli auto-memory distiller.
#
# Source: packages/kiro-cli/memory/distiller.ts — a dependency-free bun/TS
# script (only node: built-ins, no npm deps). It is the deterministic Stop-hook
# write path for kiro-cli auto-memory (see docs/plans/kiro-cli-auto-memory.md).
# This overlay ships it as two role wrappers a later checkpoint's v3 hooks invoke
# by absolute store path:
#   kiro-memory-distiller  — Stop / Manual: distill the session's new turns.
#   kiro-memory-flush      — SessionStart: flush prior sessions' dropped tails
#                            (`distiller.ts --flush` → mainFlush()).
#
# Build pattern mirrors overlays/mcp-servers/openmemory-mcp.nix: makeWrapper over
# ${bun}/bin/bun --add-flags <entry>. The script has nothing to compile, so the
# install just copies the entry to the store and wraps it. git is on the wrapper
# PATH (--suffix, ambient-first) because the distiller shells out to
# `git rev-parse --git-common-dir` to derive the worktree-shared project_id (D19);
# the openmemory-mem backend helper is intentionally best-effort-absent until a
# later checkpoint (the file buffer works without it).
#
# Cache-hit parity: every build input routes through `ourPkgs` (this repo's
# nixpkgs pin), never `final`/`prev`. See .claude/rules/overlays.md.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) bun git lib makeWrapper stdenvNoCC;

  gitPath = lib.makeBinPath [git];
in
  stdenvNoCC.mkDerivation {
    pname = "kiro-memory-distiller";
    version = "0.1.0";
    src = ../packages/kiro-cli/memory;

    nativeBuildInputs = [makeWrapper];

    # Dependency-free script: nothing to configure or build.
    dontConfigure = true;
    dontBuild = true;

    # Run the distiller's own suite at build time. `bun test` spawns the
    # distiller as a subprocess and drives a real `git init`, so both bun and
    # git must be on the check PATH; HOME points at a writable temp for git.
    doCheck = true;
    nativeCheckInputs = [bun git];
    checkPhase = ''
      runHook preCheck
      HOME="$TMPDIR" ${bun}/bin/bun test
      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      install -Dm644 distiller.ts "$out/lib/kiro-memory/distiller.ts"
      makeWrapper ${bun}/bin/bun "$out/bin/kiro-memory-distiller" \
        --add-flags "$out/lib/kiro-memory/distiller.ts" \
        --suffix PATH : "${gitPath}"
      makeWrapper ${bun}/bin/bun "$out/bin/kiro-memory-flush" \
        --add-flags "$out/lib/kiro-memory/distiller.ts" \
        --add-flags "--flush" \
        --suffix PATH : "${gitPath}"
      runHook postInstall
    '';

    # End-to-end wrapper smoke: metadata-only stdin with no session_id makes both
    # entry points no-op and exit 0 (main() bails on an invalid session id; the
    # flush scan finds no prior-session state). Proves bun resolves the wrapped
    # entry and the top-level dispatch runs, independent of any real transcript.
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      echo '{}' | "$out/bin/kiro-memory-distiller"
      echo '{}' | "$out/bin/kiro-memory-flush"
      runHook postInstallCheck
    '';

    meta = {
      description = "Deterministic Stop-hook memory distiller for kiro-cli auto-memory";
      mainProgram = "kiro-memory-distiller";
      license = lib.licenses.unlicense;
      platforms = lib.platforms.unix;
    };
  }
