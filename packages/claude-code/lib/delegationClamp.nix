# writeShellApplication wrapper for the heron_brook delegation-clamp mitigation.
# See packages/claude-code/docs/heron-brook-clamp.md for why this exists.
#
# The hook's stdout payload is serialized HERE, at Nix eval time, with
# builtins.toJSON — not assembled by the script at runtime. That is strictly
# stronger than a runtime serializer (it cannot be malformed by a surprising
# `text` value) and it keeps jq off the output path entirely; jq remains a
# runtimeInput only for READING session_id off the hook envelope.
#
# The serialized payload lands in its OWN store file rather than as a string
# literal inside the script. Inlining it broke the build twice over: the JSON's
# quotes and backslashes tripped shellcheck's SC2089/SC2090, and its non-ASCII
# text made shellcheck itself die with `commitBuffer: invalid argument (cannot
# encode character '\8212')` under the build sandbox's C locale — an error that
# names neither the character nor the file. A separate file also matches what
# mkClaude's hook-command coercion is built for: supporting files riding the
# store closure at absolute paths, since Claude runs hooks with cwd = project
# root and relative companion paths are unsafe.
#
# runtimeInputs give absolute-PATH access under a stripped PATH (nix-standards):
# coreutils (mkdir/touch/rm/cat), findutils (marker prune), jq (stdin parse).
{
  lib,
  pkgs,
  # The standing request injected as user-side context. Wording is load-bearing —
  # see packages/claude-code/docs/heron-brook-clamp.md before changing it.
  text,
}: let
  payloadFile = pkgs.writeText "claude-delegation-clamp-payload.json" (
    builtins.toJSON {
      hookSpecificOutput = {
        hookEventName = "UserPromptSubmit";
        additionalContext = text;
      };
    }
  );
in
  pkgs.writeShellApplication {
    name = "claude-delegation-clamp";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.jq
    ];
    text = ''
      DELEGATION_CLAMP_PAYLOAD_FILE=${lib.escapeShellArg "${payloadFile}"}
      export DELEGATION_CLAMP_PAYLOAD_FILE
      ${builtins.readFile ./delegation-clamp.sh}
    '';
  }
