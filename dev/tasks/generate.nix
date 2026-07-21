# dev/tasks/generate.nix — Content generation devenv tasks.
{
  pkgs,
  instr,
  ...
}: let
  cu = "${pkgs.coreutils}/bin";
  # cmp ships in diffutils, NOT coreutils. Getting this wrong fails
  # silently: the call sits in an `if` condition, where a missing binary
  # is just a false branch and errexit never trips, so every file gets
  # rewritten on every shell entry instead of being skipped.
  du = "${pkgs.diffutils}/bin";

  # Materialize generated instruction files into the working tree.
  #
  # ONE mechanism for all five groups: a real file copy. Kiro discovers
  # steering by scanning a directory and the scan skips symlinks, so devenv
  # `files.*` (symlink mode) could silently leave .kiro/steering unreadable.
  # The tracked outputs additionally cannot be symlinks at all — a store
  # symlink commits as mode 120000 holding an absolute /nix/store path,
  # meaningless in any other clone.
  #
  # Idempotent on purpose: an unchanged file is never rewritten, so mtimes
  # don't churn on every direnv reload. Writes go through mktemp+mv so a
  # concurrent agent session (this repo is routinely co-occupied) observes
  # old bytes or new bytes, never a partial file. devenv's own
  # copyMode="copy" does an unconditional `rm -rf` + `cp`, which has both
  # of those hazards and cannot prune orphans.
  syncLib = ''
    # direnv activates in SUBDIRECTORIES and a task's default cwd is the
    # caller's cwd, so relative destinations must be anchored.
    cd "$DEVENV_ROOT"

    sync_file() {
      # `if` form rather than `cmp && return` — an AND-list whose final
      # command fails would trip errexit.
      if ${du}/cmp -s "$1" "$2" 2>/dev/null; then return 0; fi
      ${cu}/mkdir -p "$(${cu}/dirname "$2")"
      # Hidden prefix: a crashed run must not strand a visible *.md.XXXXXX
      # in a gitignored dir where nothing would ever notice it.
      tmp=$(${cu}/mktemp "$(${cu}/dirname "$2")/.$(${cu}/basename "$2").XXXXXX")
      ${cu}/cp -L "$1" "$tmp"
      ${cu}/chmod 0644 "$tmp"
      ${cu}/mv -f "$tmp" "$2"
      log "materialized $2"
    }

    # Mirror <srcdir>/*.md into <destdir>, pruning generated files that no
    # longer exist upstream. All three managed dirs are 100% generated, so
    # pruning is safe — and it closes a gap BOTH old mechanisms left open:
    # a renamed fragment used to strand a stale rule/steering file forever,
    # invisible because those dirs are gitignored.
    sync_dir() {
      ${cu}/mkdir -p "$2"
      for f in "$1"/*.md; do
        [ -e "$f" ] || continue
        sync_file "$f" "$2/$(${cu}/basename "$f")"
      done
      for f in "$2"/*.md; do
        [ -e "$f" ] || continue
        if [ ! -e "$1/$(${cu}/basename "$f")" ]; then
          ${cu}/rm -f "$f"
          log "pruned stale $f"
        fi
      done
    }
  '';

  syncEco = {
    agents = ''sync_file ${instr.agents}/AGENTS.md AGENTS.md'';
    claude = ''
      sync_file ${instr.claude}/CLAUDE.md CLAUDE.md
      sync_dir ${instr.claude}/rules .claude/rules
    '';
    copilot = ''
      sync_file ${instr.copilot}/copilot-instructions.md .github/copilot-instructions.md
      sync_dir ${instr.copilot}/instructions .github/instructions
    '';
    kiro = ''sync_dir ${instr.kiro} .kiro/steering'';
  };
  bashPreamble = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
  '';

  log = ''log() { echo "==> $*" >&2; }'';

  # Copy one generated file out of the nix store into the working tree.
  # Used by the two generate:repo:* tasks; the instruction files go
  # through sync_file above instead.
  #
  # Unlinks the destination first so the copy is idempotent even when the
  # target is a store symlink: a plain `cp` would then either resolve to
  # the very file being copied ("are the same file", fatal under errexit)
  # or follow the link and try to write into the read-only store. Uses
  # `rm -f` rather than `cp --remove-destination`, which the nix coding
  # standard forbids; either way only the working-tree entry is removed,
  # never anything under /nix/store.
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
        ${syncLib}
        ${syncEco.agents}
      '';
    };

    "generate:instructions:claude" = {
      description = "Generate CLAUDE.md and Claude rule files from fragments";
      before = ["generate:instructions"];
      exec = ''
        ${bashPreamble}
        ${log}
        ${syncLib}
        ${syncEco.claude}
      '';
    };

    "generate:instructions:copilot" = {
      description = "Generate Copilot instruction files from fragments";
      before = ["generate:instructions"];
      exec = ''
        ${bashPreamble}
        ${log}
        ${syncLib}
        ${syncEco.copilot}
      '';
    };

    "generate:instructions:kiro" = {
      description = "Generate Kiro steering files from fragments";
      before = ["generate:instructions"];
      exec = ''
        ${bashPreamble}
        ${log}
        ${syncLib}
        ${syncEco.kiro}
      '';
    };

    # ── Bootstrap ────────────────────────────────────────────────────
    # Runs on every `devenv shell`, `direnv reload`, `devenv up`,
    # `devenv reload` and `devenv test`. THIS is what replaces the deleted
    # devenv `files.*` block: a fresh clone has no CLAUDE.md,
    # .claude/rules/* or .kiro/steering/* (all gitignored), and this
    # creates them as real files before the prompt appears.
    #
    # No `nix build` here — ${instr.*} are eval-time store paths, realized
    # when devenv builds the shell itself. Steady-state cost is ~48 `cmp`s
    # on small markdown files, next to a full-tree treefmt that already
    # runs on every entry.
    #
    # after devenv:files:cleanup — cleanup deletes paths dropped from
    # files.*, so running after it repairs any such deletion within the
    # same shell entry. The migration can never leave the tree short a
    # gitignored file.
    #
    # Deliberately a LEAF, not the mid-graph `generate:instructions`
    # aggregate: devenv's RunMode::All walks incoming edges transitively
    # from the root but outgoing edges only from the root, so hooking the
    # aggregate here would be fragile (cachix/devenv#2337). Deliberately
    # NOT `before devenv:treefmt:run` either — an unresolved task name in
    # `before` is a hard error, which would couple this to treefmt.enable
    # staying true, and the content is already a treefmt fixed point.
    "generate:instructions:materialize" = {
      description = "Materialize generated instruction files on shell entry";
      after = ["devenv:files:cleanup"];
      before = ["devenv:enterShell"];
      exec = ''
        ${bashPreamble}
        ${log}
        ${syncLib}
        ${syncEco.agents}
        ${syncEco.claude}
        ${syncEco.copilot}
        ${syncEco.kiro}
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
