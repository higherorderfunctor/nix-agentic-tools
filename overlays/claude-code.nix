# Claude Code — override nixpkgs' claude-code with nvfetcher-tracked version.
# Uses the same buildNpmPackage override pattern as nixos-config but with
# hashes tracked in the sidecar (not hardcoded).
#
# nixpkgs' postPatch copies its own lockfile into src. We must override
# postPatch to use our lockfile so npmDepsHash stays consistent.
#
# This package also wraps `bin/claude` with a Bun-runtime wrapper that
# prefers a writable cli.js at $XDG_STATE_HOME/claude-code-buddy/lib/cli.js
# (used by the buddy HM module) and falls back to the store cli.js
# otherwise. The wrapper is harmless when no buddy is configured —
# claude-code just runs the store cli.js under Bun.
#
# Why Bun: claude-code's buddy hash uses Bun.hash (wyhash) when Bun is
# available, otherwise fnv1a. Running under Bun lets the buddy salt
# search use the simpler wyhash path. Startup overhead is negligible.
#
# Buddy user-facing options live in packages/claude-code/lib/mkClaude.nix
# (inside the factory's `options.buddy` submodule). The actual buddy
# activation script that consumes `$XDG_STATE_HOME/claude-code-buddy/lib/cli.js`
# lives in the consumer repo (nixos-config's own modules/claude-code-buddy/
# HM module) — this overlay just prepares the wrapper that supports it.
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` so the base claude-code
# derivation, buildNpmPackage, fetchzip, bun, writeShellScript,
# symlinkJoin all route through this repo's pinned nixpkgs instead of
# the consumer's. `passthru.baseClaudeCode` exposes OUR pinned
# claude-code so a consumer-side buddy activation script can close over
# the same store paths CI builds and pushes to cachix.
# See dev/fragments/overlays/overlay-pattern.md
{
  inputs,
  final,
  nv,
  lockFile,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };

  baseClaudeCode = ourPkgs.claude-code.override (_: {
    buildNpmPackage = args:
      ourPkgs.buildNpmPackage (finalAttrs: let
        a = (ourPkgs.lib.toFunction args) finalAttrs;
      in
        a
        // {
          inherit (nv) version;
          src = ourPkgs.fetchzip {
            url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${nv.version}.tgz";
            hash = nv.srcHash;
          };
          inherit (nv) npmDepsHash;
          postPatch = ''
            cp ${lockFile} package-lock.json

            # https://github.com/anthropics/claude-code/issues/15195
            substituteInPlace cli.js \
                  --replace-fail '#!/bin/sh' '#!/usr/bin/env sh'
          '';
        });
  });

  storeCliJs = "${baseClaudeCode}/lib/node_modules/@anthropic-ai/claude-code/cli.js";

  wrapperScript = ourPkgs.writeShellScript "claude-buddy-wrapper" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    USER_LIB="''${XDG_STATE_HOME:-$HOME/.local/state}/claude-code-buddy/lib"

    if [ -f "$USER_LIB/cli.js" ]; then
      CLI="$USER_LIB/cli.js"
    else
      CLI="${storeCliJs}"
    fi

    exec ${ourPkgs.bun}/bin/bun run "$CLI" "$@"
  '';
in
  ourPkgs.symlinkJoin {
    inherit (baseClaudeCode) name version;
    paths = [baseClaudeCode];
    postBuild = ''
      rm -f $out/bin/claude
      cp ${wrapperScript} $out/bin/claude
      chmod +x $out/bin/claude
    '';
    meta = baseClaudeCode.meta or {};
    passthru =
      (baseClaudeCode.passthru or {})
      // {
        inherit baseClaudeCode;
      };
  }
