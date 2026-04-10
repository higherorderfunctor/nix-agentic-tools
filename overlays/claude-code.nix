# Claude Code — override nixpkgs' claude-code with nvfetcher-tracked version.
# Uses the same buildNpmPackage override pattern as nixos-config but with
# hashes tracked in the sidecar (not hardcoded).
#
# nixpkgs' postPatch copies its own lockfile into src. We must override
# postPatch to use OUR lockfile (locks/claude-code-package-lock.json) because
# when our version is newer than nixpkgs' version, the upstream lockfile in
# nixpkgs' source won't satisfy the newer package.json.
#
# Unfree: wrapped by `wrapUnfree` in default.nix so the consumer's
# allowUnfree config is respected. See overlays/README.md.
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` for cache-hit parity.
# `passthru.baseClaudeCode` exposes the pinned derivation so buddy
# activation scripts can close over the same store paths CI builds.
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
  # Inner build: ourPkgs for cache-hit parity. wrapUnfree in default.nix
  # adds the consumer-facing unfree check on top.
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
