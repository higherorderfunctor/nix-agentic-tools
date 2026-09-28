# Claude plugins as personal-plugin directories.
# cspell:ignore dotglob
#
# Claude Code 2.1.157+ loads every directory under `<configDir>/skills/` that
# carries a `.claude-plugin/plugin.json` as a personal plugin. The manifest's
# `name` is the plugin's identity: MCP tools it serves are named
# `mcp__plugin_<name>_<server>__<tool>`.
{
  lib,
  pkgs,
}: let
  jsonFormat = pkgs.formats.json {};
in {
  # A consumer plugin, wrapped so a manifest can be synthesized for a source
  # that lacks one. Only the top-level entries are linked, so each component
  # directory stays ONE symlink to the original: Claude's `agents/` and
  # `commands/` scanners accept regular files only, and a tree of per-file
  # links (what `symlinkJoin` or a recursive link would build) drops every
  # agent and command the plugin ships. The result is delivered as a single
  # directory link for the same reason.
  mkPluginEntry = name: plugin:
    pkgs.runCommand "claude-code-plugin-${lib.strings.sanitizeDerivationName name}" {} ''
      ${pkgs.coreutils}/bin/mkdir -p "$out"

      shopt -s dotglob nullglob
      for entry in "${plugin}"/*; do
        ln -s "$entry" "$out/$(basename "$entry")"
      done

      if [[ ! -e $out/.claude-plugin/plugin.json ]]; then
        # Replace the linked manifest directory with a real one so the
        # generated manifest can sit beside any existing contents.
        ${pkgs.coreutils}/bin/rm -f "$out/.claude-plugin"
        ${pkgs.coreutils}/bin/mkdir -p "$out/.claude-plugin"
        for entry in "${plugin}"/.claude-plugin/*; do
          ln -s "$entry" "$out/.claude-plugin/$(basename "$entry")"
        done
        install -m644 ${jsonFormat.generate "claude-code-plugin-${lib.strings.sanitizeDerivationName name}.json" {inherit name;}} "$out/.claude-plugin/plugin.json"
      fi
    '';
}
