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
# Buddy state management lives in modules/claude-code-buddy/.
#
# The `...` absorbs the `inputs` arg that packages/ai-clis/default.nix
# threads through every per-package import for Phase 3.7 of the
# architecture-foundation plan (cache-hit parity). Not yet consumed
# in this file; plumbing-only for now.
{
  final,
  prev,
  nv,
  lockFile,
  ...
}: let
  baseClaudeCode = prev.claude-code.override (_: {
    buildNpmPackage = args:
      final.buildNpmPackage (finalAttrs: let
        a = (final.lib.toFunction args) finalAttrs;
      in
        a
        // {
          inherit (nv) version;
          src = final.fetchzip {
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

  wrapperScript = final.writeShellScript "claude-buddy-wrapper" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    USER_LIB="''${XDG_STATE_HOME:-$HOME/.local/state}/claude-code-buddy/lib"

    if [ -f "$USER_LIB/cli.js" ]; then
      CLI="$USER_LIB/cli.js"
    else
      CLI="${storeCliJs}"
    fi

    exec ${final.bun}/bin/bun run "$CLI" "$@"
  '';
in
  final.symlinkJoin {
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
