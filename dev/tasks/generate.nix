# dev/tasks/generate.nix — Content generation devenv tasks.
_: let
  bashPreamble = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
  '';

  log = ''log() { echo "==> $*" >&2; }'';

  # Copy one generated file out of the nix store into the working tree.
  #
  # Destinations are frequently devenv `files.*` symlinks pointing INTO
  # the store (see devenv.nix), which breaks a plain `cp` two ways: when
  # the generated content is unchanged the link already resolves to the
  # very file being copied, so cp aborts with "are the same file" (fatal
  # under errexit); and otherwise cp follows the link and tries to write
  # into the read-only store. Unlinking the destination first avoids
  # both, and — unlike `cp --remove-destination`, which the nix coding
  # standard forbids — only ever removes the working-tree link, never
  # anything under /nix/store.
  #
  # chmod because store files are 0444 and the copy inherits that,
  # leaving a read-only file in the tree. generate:site:prose already
  # does the same for its directory copies.
  copyOut = ''
    copy_out() {
      rm -f "$2"
      cp -f "$1" "$2"
      chmod u+w "$2"
    }
  '';
in {
  tasks = {
    "build:all" = {
      description = "Build all packages with nix-fast-build";
      exec = ''
        ${bashPreamble}
        ${log}
        log "Building all packages"
        nix-fast-build --flake ".#packages" --skip-cached --no-link
        log "All packages built"
      '';
    };

    # BROKEN: `.#repo-contributing` and `.#repo-readme` flake outputs
    # don't exist. Running `devenv tasks run --mode before generate:repo`
    # will fail with "attribute missing" on both tasks below. The
    # `readmeMd` / `contributingMd` strings exist in `dev/generate.nix`
    # but aren't exposed as flake packages the way `instructions-*` are.
    # Fix: add `repo-readme` / `repo-contributing` packages to
    # `flake.nix` that wrap those strings in `pkgs.writeText`, paralleling
    # the existing `instructions-claude` / `instructions-copilot` / etc.
    # Until then, README.md and CONTRIBUTING.md must be edited manually
    # (use `dev/data.nix` as the source of truth for the data-driven rows).
    "generate:repo:contributing" = {
      description = "Generate CONTRIBUTING.md from fragments and nix data";
      before = ["generate:repo"];
      exec = ''
        ${bashPreamble}
        ${log}
        ${copyOut}
        log "Building CONTRIBUTING.md"
        src=$(nix build .#repo-contributing --no-link --print-out-paths)
        copy_out "$src" CONTRIBUTING.md
        log "CONTRIBUTING.md updated"
      '';
    };

    "generate:repo:readme" = {
      description = "Generate README.md from fragments and nix data";
      before = ["generate:repo"];
      exec = ''
        ${bashPreamble}
        ${log}
        ${copyOut}
        log "Building README.md"
        src=$(nix build .#repo-readme --no-link --print-out-paths)
        copy_out "$src" README.md
        log "README.md updated"
      '';
    };

    "generate:repo" = {
      description = "Generate all repo front-door files";
      after = [
        "generate:repo:contributing"
        "generate:repo:readme"
      ];
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
        ${copyOut}
        log "Building AGENTS.md"
        src=$(nix build .#instructions-agents --no-link --print-out-paths)
        copy_out "$src/AGENTS.md" AGENTS.md
        log "AGENTS.md updated"
      '';
    };

    "generate:instructions:claude" = {
      description = "Generate CLAUDE.md and Claude rule files from fragments";
      before = ["generate:instructions"];
      exec = ''
        ${bashPreamble}
        ${log}
        ${copyOut}
        log "Building CLAUDE.md + Claude rules"
        src=$(nix build .#instructions-claude --no-link --print-out-paths)
        copy_out "$src/CLAUDE.md" CLAUDE.md
        mkdir -p .claude/rules
        for f in "$src"/rules/*.md; do
          [ -f "$f" ] && copy_out "$f" ".claude/rules/$(basename "$f")"
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
        ${copyOut}
        log "Building Copilot instructions"
        src=$(nix build .#instructions-copilot --no-link --print-out-paths)
        mkdir -p .github/instructions
        copy_out "$src/copilot-instructions.md" .github/copilot-instructions.md
        for f in "$src"/instructions/*.md; do
          [ -f "$f" ] && copy_out "$f" ".github/instructions/$(basename "$f")"
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
        ${copyOut}
        log "Building Kiro steering files"
        src=$(nix build .#instructions-kiro --no-link --print-out-paths)
        mkdir -p .kiro/steering
        for f in "$src"/*.md; do
          [ -f "$f" ] && copy_out "$f" ".kiro/steering/$(basename "$f")"
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
        # Formatting happens inside the nix derivation (treefmt in
        # runCommand). The task just copies pre-formatted store output.
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

    "generate:site:search" = {
      description = "Build Pagefind search index for doc site";
      after = ["generate:site:prose" "generate:site:reference" "generate:site:snippets"];
      before = ["generate:site"];
      exec = ''
        ${bashPreamble}
        ${log}
        log "Building mdbook site for indexing"
        mdbook build docs/
        log "Indexing with Pagefind"
        pagefind --site result-docs
        log "Search index built"
      '';
    };

    "generate:site" = {
      description = "Generate complete doc site";
      after = [
        "generate:site:prose"
        "generate:site:reference"
        "generate:site:search"
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
