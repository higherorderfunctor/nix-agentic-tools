# Copy fragment-generated repository instructions out of the Nix store as
# portable real files. Used by devenv shell entry and its flake contract test.
{
  instr,
  pkgs,
}: let
  shellStrict = import ../config/shell-strict.nix;
in
  pkgs.writeShellApplication {
    name = "materialize-repo-instructions";
    extraShellCheckFlags = shellStrict.shellcheckFlags;
    inherit (shellStrict) bashOptions;
    text = ''
      ${shellStrict.shoptHeader}

      if [ "$#" -ne 2 ]; then
        echo "usage: materialize-repo-instructions <agents|claude|copilot|kiro|all> <repository-root>" >&2
        exit 2
      fi
      group="$1"
      root="$2"
      if [ ! -d "$root" ]; then
        echo "materialize-repo-instructions: repository root does not exist: $root" >&2
        exit 1
      fi
      cd "$root"

      log() { echo "==> $*" >&2; }

      sync_file() {
        src="$1"
        dest="$2"
        if [ ! -L "$dest" ] \
          && [ -f "$dest" ] \
          && ${pkgs.diffutils}/bin/cmp -s "$src" "$dest" \
          && [ "$(${pkgs.coreutils}/bin/stat --format=%a "$dest")" = 644 ]; then
          return 0
        fi
        ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$dest")"
        # A hidden temp plus same-filesystem rename means concurrent shell
        # entries observe either the old complete file or the new one.
        tmp="$(${pkgs.coreutils}/bin/mktemp "$(${pkgs.coreutils}/bin/dirname "$dest")/.$(${pkgs.coreutils}/bin/basename "$dest").XXXXXX")"
        trap '${pkgs.coreutils}/bin/rm -f "$tmp"' RETURN
        ${pkgs.coreutils}/bin/cp -L "$src" "$tmp"
        ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
        ${pkgs.coreutils}/bin/mv -f "$tmp" "$dest"
        trap - RETURN
        log "materialized $dest"
      }

      sync_dir() {
        src_dir="$1"
        dest_dir="$2"
        ${pkgs.coreutils}/bin/mkdir -p "$dest_dir"
        found=""
        for src in "$src_dir"/*.md; do
          [ -e "$src" ] || continue
          found=1
          sync_file "$src" "$dest_dir/$(${pkgs.coreutils}/bin/basename "$src")"
        done
        if [ -z "$found" ]; then
          echo "materialize-repo-instructions: source directory is empty: $src_dir" >&2
          return 1
        fi
        for dest in "$dest_dir"/*.md; do
          [ -e "$dest" ] || [ -L "$dest" ] || continue
          if [ ! -e "$src_dir/$(${pkgs.coreutils}/bin/basename "$dest")" ]; then
            ${pkgs.coreutils}/bin/rm -f "$dest"
            log "pruned stale $dest"
          fi
        done
      }

      materialize_agents() {
        sync_file ${instr.agents}/AGENTS.md AGENTS.md
      }
      materialize_claude() {
        sync_file ${instr.claude}/CLAUDE.md CLAUDE.md
        sync_dir ${instr.claude}/rules .claude/rules
      }
      materialize_copilot() {
        sync_file ${instr.copilot}/copilot-instructions.md .github/copilot-instructions.md
        sync_dir ${instr.copilot}/instructions .github/instructions
      }
      materialize_kiro() {
        sync_dir ${instr.kiro} .kiro/steering
      }

      case "$group" in
        agents) materialize_agents ;;
        claude) materialize_claude ;;
        copilot) materialize_copilot ;;
        kiro) materialize_kiro ;;
        all)
          materialize_agents
          materialize_claude
          materialize_copilot
          materialize_kiro
          ;;
        *)
          echo "materialize-repo-instructions: unknown group: $group" >&2
          exit 2
          ;;
      esac
    '';
  }
