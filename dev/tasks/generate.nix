# dev/tasks/generate.nix — Content generation devenv tasks.
_: let
  bashPreamble = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
  '';

  log = ''log() { echo "==> $*" >&2; }'';
in {
  tasks = {
    "generate:instructions:agents" = {
      description = "Generate AGENTS.md from fragments";
      before = ["generate:instructions"];
      exec = ''
        ${bashPreamble}
        ${log}
        log "Building AGENTS.md"
        src=$(nix build .#instructions-agents --no-link --print-out-paths)
        cp -f "$src" AGENTS.md
        log "AGENTS.md updated"
      '';
    };

    "generate:instructions:claude" = {
      description = "Generate CLAUDE.md from fragments";
      before = ["generate:instructions"];
      exec = ''
        ${bashPreamble}
        ${log}
        log "Building CLAUDE.md"
        src=$(nix build .#instructions-claude --no-link --print-out-paths)
        cp -f "$src" CLAUDE.md
        log "CLAUDE.md updated"
      '';
    };

    "generate:instructions:copilot" = {
      description = "Generate Copilot instruction files from fragments";
      before = ["generate:instructions"];
      exec = ''
        ${bashPreamble}
        ${log}
        log "Building Copilot instructions"
        src=$(nix build .#instructions-copilot --no-link --print-out-paths)
        mkdir -p .github/instructions
        cp -f "$src/copilot-instructions.md" .github/copilot-instructions.md
        for f in "$src"/instructions/*.md; do
          [ -f "$f" ] && cp -f "$f" ".github/instructions/$(basename "$f")"
        done
        log "Copilot instructions updated"
      '';
    };

    "generate:instructions:kiro" = {
      description = "Generate Kiro steering files from fragments";
      before = ["generate:instructions"];
      exec = ''
        ${bashPreamble}
        ${log}
        log "Building Kiro steering files"
        src=$(nix build .#instructions-kiro --no-link --print-out-paths)
        mkdir -p .kiro/steering
        for f in "$src"/*.md; do
          [ -f "$f" ] && cp -f "$f" ".kiro/steering/$(basename "$f")"
        done
        log "Kiro steering files updated"
      '';
    };

    "generate:instructions" = {
      description = "Generate all instruction files";
      after = [
        "generate:instructions:agents"
        "generate:instructions:claude"
        "generate:instructions:copilot"
        "generate:instructions:kiro"
      ];
      exec = ''
        ${bashPreamble}
        ${log}
        log "All instruction files generated"
      '';
    };
  };
}
