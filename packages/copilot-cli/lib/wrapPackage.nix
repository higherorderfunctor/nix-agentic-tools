# Wrap copilot-cli so it reads the MCP config the module renders — shared by
# BOTH backends (DRY). Returns the raw package when nothing needs wrapping.
#
# `environmentVariables` are baked as `--set` args on BOTH backends. devenv
# used to pass `{}` and export through its native `env` attrset instead; that
# wrote the PROJECT SHELL, handing every variable to the developer's own
# session, so it was retired on 2026-08-10.
#
# devenv independently needs the flag injection regardless, because Copilot
# reads MCP config from `$HOME/.copilot/mcp-config.json` and from whatever
# `--additional-mcp-config` points at, and NOTHING project-local. See
# dev/fragments/ai-clis/copilot-config-delivery.md for the syscall trace.
#
# ── Why this file exists ────────────────────────────────────────────────────
# This wrapper was inlined TWICE, once per backend, and that duplication cost
# two separate releases: the identical PAIR of defects below shipped in the HM
# copy (fixed in #767) and then again, unchanged, in the devenv copy (fixed in
# #769). That is one defect in duplicated code wearing two PR numbers. Keep both
# backends on this function so a third copy cannot drift.
#
# ── The two load-bearing details ────────────────────────────────────────────
# 1. `\''${<rootVar>}` is ESCAPED so it reaches the generated wrapper
#    UNEXPANDED and the LAUNCHING shell expands it. This string is interpolated
#    into `postBuild`, so an unescaped `$HOME` is expanded by the BUILDER's
#    shell — and nixpkgs builds run with `HOME=/homeless-shelter`. The shipped
#    wrapper literally read:
#
#      exec … --additional-mcp-config /homeless-shelter/.copilot/mcp-config.json "$@"
#
#    a path that exists on no machine. Escaping also keeps the derivation
#    user-independent; baking a concrete home directory would work but would
#    fork the store path per user for no gain.
#
# 2. The `@` prefix marks the value a FILE PATH. Copilot's own help:
#
#      --additional-mcp-config <json>   JSON string or file path (prefix with @)
#
#    Without it the CLI parses the path STRING as JSON and dies with
#    `Invalid JSON: expected value at line 1 column 1` on every session start.
#
# They MASKED each other: JSON parsing failed before anything opened the path,
# so the bogus path never got the chance to report ENOENT. `--version` and
# `--help` kept working — they short-circuit before config load — which is why
# a "does it start?" check missed both.
#
# Neither is visible from the Nix side; the generated script is well-formed
# either way. So packages/copilot-cli/checks/copilot-wrapper-argv.nix RUNS this wrapper against a
# stub that prints its argv, under a CONTROLLED HOME / DEVENV_ROOT, instead of
# string-matching the emitted bash. A grep proves the text is present; only
# running it proves the root var still expands at launch and that the value
# survives as a single argv token.
{
  lib,
  pkgs,
}: {
  package,
  # NAME of the environment variable the launched shell expands to reach the
  # rendered mcp-config.json: "HOME" under Home Manager, "DEVENV_ROOT" under
  # devenv. Passed as a name rather than a ready-made path so the escaping
  # above happens exactly once, here, rather than once per caller — which is
  # the specific thing that went wrong twice.
  rootVar,
  configDir,
  mcp ? false,
  environmentVariables ? {},
}: let
  mcpConfigPath = ''\''${${rootVar}}/${configDir}/mcp-config.json'';
in
  # The shared launcher returns the bare package when nothing needs wrapping.
  # Imported by path: packages/copilot-cli/checks/copilot-wrapper-argv.nix
  # calls this file with a `lib` that carries no `lib.ai`.
  import ../../../lib/ai/launcher.nix pkgs {
    inherit environmentVariables package;
    exe = "copilot";
    flags = lib.optional mcp ''--add-flags "--additional-mcp-config @${mcpConfigPath}"'';
    name = "copilot-cli-wrapped";
  }
