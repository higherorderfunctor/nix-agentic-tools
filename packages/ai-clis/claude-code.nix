# Claude Code — override nixpkgs' claude-code with nvfetcher-tracked version.
# Uses the same buildNpmPackage override pattern as nixos-config but with
# hashes tracked in the sidecar (not hardcoded).
#
# nixpkgs' postPatch copies its own lockfile into src. We must override
# postPatch to use our lockfile so npmDepsHash stays consistent.
{
  final,
  prev,
  nv,
  lockFile,
  withBuddyFn,
}: let
  package = prev.claude-code.override (_: {
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
          passthru =
            (a.passthru or {})
            // {
              withBuddy = withBuddyFn package;
            };
        });
  });
in
  package
