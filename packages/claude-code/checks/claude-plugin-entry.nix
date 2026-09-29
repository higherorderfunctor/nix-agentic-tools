# Builds `mkPluginEntry` (packages/claude-code/lib/plugin.nix) and asserts the
# directory it produces. The module-eval tests only see the derivation's name,
# so this is the one place its shell logic actually runs.
#
# Three sources cover its branches:
#
#   * bare    — no `.claude-plugin/` at all: the manifest is synthesized.
#   * partial — a `.claude-plugin/` without `plugin.json`: the directory is
#               rebuilt as a real one, its contents stay links, and the
#               manifest is synthesized beside them.
#   * owned   — ships its own `plugin.json`: kept as is, never replaced.
#
# Component directories must stay ONE symlink each: Claude's `agents/` and
# `commands/` scanners accept regular files only, so a tree of per-file links
# would drop every agent and command the plugin ships.
{
  lib,
  pkgs,
  ...
}: let
  inherit (import ../lib/plugin.nix {inherit lib pkgs;}) mkPluginEntry;

  mkSource = name: script:
    pkgs.runCommandLocal "claude-plugin-fixture-${name}" {} ''
      mkdir -p "$out"
      cd "$out"
      ${script}
    '';

  bare = mkSource "bare" ''
    mkdir agents commands
    printf -- '---\nname: a\n---\n' > agents/a.md
    printf 'body\n' > commands/c.md
    printf 'hidden\n' > .hidden
  '';
  partial = mkSource "partial" ''
    mkdir .claude-plugin agents
    printf '{}\n' > .claude-plugin/marketplace.json
  '';
  owned = mkSource "owned" ''
    mkdir .claude-plugin commands
    printf '{"name":"upstream-name"}\n' > .claude-plugin/plugin.json
  '';
in {
  checks.claude-plugin-entry =
    pkgs.runCommandLocal "claude-plugin-entry-check" {
      nativeBuildInputs = [pkgs.coreutils pkgs.jq];
      bareEntry = mkPluginEntry "bare-key" bare;
      bareSrc = bare;
      ownedEntry = mkPluginEntry "owned-key" owned;
      ownedSrc = owned;
      partialEntry = mkPluginEntry "partial-key" partial;
      partialSrc = partial;
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      fail=0
      ok() { echo "ok   - $1"; }
      bad() { fail=1; echo "FAIL - $1" >&2; }
      check() {
        local label=$1
        shift
        if "$@"; then ok "$label"; else bad "$label"; fi
      }

      # linked <entry> <src> <relpath>: one symlink pointing at the source's path.
      linked() { [[ -L $1/$3 && "$(readlink "$1/$3")" == "$2/$3" ]]; }
      # named <manifest> <name>: the manifest's `name` field.
      named() { jq -e --arg n "$2" '.name == $n' "$1" >/dev/null; }
      # synthesized <entry> <key>: a regular manifest carrying only the key.
      synthesized() {
        [[ -d $1/.claude-plugin && ! -L $1/.claude-plugin ]] \
          && [[ -f $1/.claude-plugin/plugin.json && ! -L $1/.claude-plugin/plugin.json ]] \
          && jq -e --arg n "$2" '. == {name: $n}' "$1/.claude-plugin/plugin.json" >/dev/null
      }

      check "bare: manifest synthesized as {name = key}" synthesized "$bareEntry" bare-key
      check "bare: agents/ is one link into the source" linked "$bareEntry" "$bareSrc" agents
      check "bare: commands/ is one link into the source" linked "$bareEntry" "$bareSrc" commands
      check "bare: root dotfile is linked" linked "$bareEntry" "$bareSrc" .hidden

      check "partial: manifest synthesized beside existing contents" synthesized "$partialEntry" partial-key
      check "partial: existing .claude-plugin content stays a link" linked "$partialEntry" "$partialSrc" .claude-plugin/marketplace.json
      check "partial: agents/ is one link into the source" linked "$partialEntry" "$partialSrc" agents

      check "owned: .claude-plugin/ is the source's own directory" linked "$ownedEntry" "$ownedSrc" .claude-plugin
      check "owned: manifest resolves to the source's file" \
        test "$(readlink -f "$ownedEntry/.claude-plugin/plugin.json")" = "$(readlink -f "$ownedSrc/.claude-plugin/plugin.json")"
      check "owned: manifest content is not synthesized" \
        named "$ownedEntry/.claude-plugin/plugin.json" upstream-name

      if ((fail)); then exit 1; fi
      touch "$out"
    '';
}
