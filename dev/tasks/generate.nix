# dev/tasks/generate.nix — Content generation devenv tasks.
_: let
  bashPreamble = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
  '';

  log = ''log() { echo "==> $*" >&2; }'';
in {
  tasks = {
    "generate:repo:readme" = {
      description = "Generate README.md from fragments and nix data";
      before = ["generate:repo"];
      exec = ''
        ${bashPreamble}
        ${log}
        log "Building README.md"
        src=$(nix build .#repo-readme --no-link --print-out-paths)
        cp -f "$src" README.md
        log "README.md updated"
      '';
    };

    "generate:repo" = {
      description = "Generate all repo front-door files";
      after = ["generate:repo:readme"];
      exec = ''
        ${bashPreamble}
        ${log}
        log "All repo docs generated"
      '';
    };

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
      description = "Generate CLAUDE.md and Claude rule files from fragments";
      before = ["generate:instructions"];
      exec = ''
        ${bashPreamble}
        ${log}
        log "Building CLAUDE.md + Claude rules"
        src=$(nix build .#instructions-claude --no-link --print-out-paths)
        cp -f "$src/CLAUDE.md" CLAUDE.md
        mkdir -p .claude/rules
        for f in "$src"/rules/*.md; do
          [ -f "$f" ] && cp -f "$f" ".claude/rules/$(basename "$f")"
        done
        log "CLAUDE.md + rules updated"
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

    "generate:site:prose" = {
      description = "Copy authored prose to docs/src/";
      before = ["generate:site"];
      exec = ''
        ${bashPreamble}
        ${log}
        log "Copying prose to docs/src/"
        src=$(nix build .#docs-site-prose --no-link --print-out-paths)
        rm -rf docs/src
        cp -rL "$src" docs/src
        chmod -R u+w docs/src
        log "Prose copied"
      '';
    };

    "generate:site:snippets" = {
      description = "Generate data table snippets for doc site";
      after = ["generate:site:prose"];
      before = ["generate:site"];
      exec = ''
        ${bashPreamble}
        ${log}
        log "Generating snippets"
        src=$(nix build .#docs-site-snippets --no-link --print-out-paths)
        mkdir -p docs/src/generated
        cp -rL "$src"/* docs/src/generated/
        chmod -R u+w docs/src/generated
        log "Snippets generated"
      '';
    };

    "generate:site:reference" = {
      description = "Generate reference pages for doc site";
      after = ["generate:site:prose"];
      before = ["generate:site"];
      exec = ''
        ${bashPreamble}
        ${log}
        log "Generating reference pages"
        src=$(nix build .#docs-site-reference --no-link --print-out-paths)
        for dir in concepts guides reference; do
          if [ -d "$src/$dir" ]; then
            mkdir -p "docs/src/$dir"
            cp -rL "$src/$dir"/* "docs/src/$dir/"
            chmod -R u+w "docs/src/$dir/"
          fi
        done
        log "Reference pages generated"
      '';
    };

    "generate:site" = {
      description = "Generate complete doc site";
      after = [
        "generate:site:prose"
        "generate:site:reference"
        "generate:site:snippets"
      ];
      exec = ''
        ${bashPreamble}
        ${log}
        log "Doc site generation complete"
      '';
    };

    "generate:all" = {
      description = "Generate all content (instructions + repo + site)";
      after = [
        "generate:instructions"
        "generate:repo"
        "generate:site"
      ];
      exec = ''
        ${bashPreamble}
        ${log}
        log "All generation complete"
      '';
    };
  };
}
