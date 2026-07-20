# Real-type drift guard for the Claude typed-hooks devenv lowering.
#
# Imports devenv's ACTUAL claude.code module (not the `attrsOf anything`
# module-eval stub) and asserts the invariant approach (B) depends on: devenv
# emits its default `git-hooks-run` entry INTO settings.json `hooks.PostToolUse`
# as a `{ matcher; hooks = [{ type = "command"; command; }]; }` block. Our typed
# `ai.claude.hooks` gap-write targets the same `files.".claude/settings.json"
# .json.hooks` and CONCATENATES with it via the formats.json list merge (proven
# in checks/module-eval.nix :: claude-hooks-settings-json-compose), so our hooks
# never clobber git-hooks-run.
#
# If a devenv bump changes this mechanism — stops emitting git-hooks-run here, or
# changes its shape — this check fails loud, signalling that the coexistence
# assumption (and the stubs below) must be re-derived. Complements
# checks/claude-code-extracted.nix, which drift-guards the BINARY's hook-event
# set rather than devenv's module.
#
# HM's `programs.claude-code` is NOT a flake input, so its lowering is asserted
# from its documented type in checks/module-eval.nix instead of here.
{
  pkgs,
  inputs,
}: let
  inherit (pkgs) lib;
  root = "/tmp/devenv-root";
  # Minimal stubs for the devenv options claude.nix reads (config.devenv.root,
  # config.git-hooks.*) and writes (files, enterShell, changelogs, infoSections).
  # Re-derive against devenv's claude.nix on a devenv bump if this eval breaks.
  ev = lib.evalModules {
    specialArgs = {inherit pkgs;};
    modules = [
      (import "${inputs.devenv}/src/modules/integrations/claude.nix")
      {
        options = {
          devenv.root = lib.mkOption {
            type = lib.types.str;
            default = root;
          };
          git-hooks.enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          git-hooks.package = lib.mkOption {
            type = lib.types.package;
            default = pkgs.hello;
          };
          files = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = {};
          };
          enterShell = lib.mkOption {
            type = lib.types.lines;
            default = "";
          };
          changelogs = lib.mkOption {
            type = lib.types.listOf lib.types.attrs;
            default = [];
          };
          infoSections = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = {};
          };
        };
        config.claude.code.enable = true;
        # → devenv's default git-hooks-run PostToolUse hook fires.
        config.git-hooks.enable = true;
      }
    ];
  };
  hooks = (ev.config.files."${root}/.claude/settings.json" or {}).json.hooks or {};
  post = hooks.PostToolUse or [];
  entry =
    if post == []
    then null
    else builtins.head post;
  handler =
    if entry == null || (entry.hooks or []) == []
    then null
    else builtins.head entry.hooks;
  ok =
    entry
    != null
    && (entry ? matcher)
    && handler != null
    && handler.type == "command"
    && handler.command != "";
in {
  claude-devenv-hooks-real-type = pkgs.runCommand "claude-devenv-hooks-real-type" {} (
    if ok
    then ''
      echo "ok — devenv emits git-hooks-run into settings.json hooks.PostToolUse as a command hook; approach-B concat coexistence holds" > "$out"
    ''
    else
      throw ''
        claude-devenv-hooks-real-type: devenv's real claude.code module no longer
        emits git-hooks-run as a settings.json PostToolUse command hook (its
        shape or mechanism changed on a devenv bump). The approach-B coexistence
        assumption — that our typed ai.claude.hooks concatenate WITH git-hooks-run
        in settings.json.hooks — may be stale. Re-verify the hooksToSettings
        lowering in packages/claude-code/lib/mkClaude.nix and re-derive this
        check's stubs against the new devenv claude.nix.
      ''
  );
}
