# dev/tasks/generate.nix — Content generation devenv tasks.
{pkgs, ...}: let
  # The Kimchi surface diagrams' render arguments. Shared verbatim with
  # checks/references/kimchi-surface-diagrams.nix, which re-renders the
  # same two files and fails on drift — so the task that fixes a drift
  # failure and the check that raises it cannot disagree about the
  # arguments. That file carries the reasoning.
  kimchiSurfaceRenders = import ../references/kimchi-surface/renders.nix {inherit (pkgs) lib;};
  bashPreamble = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
  '';

  log = ''log() { echo "==> $*" >&2; }'';

  # Copy one generated file out of the nix store into the working tree.
  # Used by the two generate:repo:* tasks; the instruction files are
  # `ai.*`'s own copies and never pass through here.
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
  # leaving a read-only file in the tree.
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

    # The task devenv.yaml's own header names as its regeneration path.
    # Writes via a temp file so a failed eval cannot truncate devenv.yaml.
    "generate:devenv-yaml" = {
      description = "Generate devenv.yaml from flake.nix + flake.lock";
      exec = ''
        ${bashPreamble}
        ${log}
        log "Generating devenv.yaml"
        tmp="$(mktemp)"
        nix eval --raw --impure --expr 'import ./config/generate-devenv-yaml.nix {}' > "$tmp"
        mv "$tmp" devenv.yaml
        log "devenv.yaml updated"
      '';
    };

    # Re-render the two SVGs beside dev/references/kimchi-surface/*.md.
    #
    # Deliberately NOT wired into `generate:all`. That aggregate's contract
    # is the instruction and repo-document projections, which every
    # contributor regenerates; this is one dev reference, and it moves only
    # when someone runs a fresh scan of a single CLI. checks/references/kimchi-surface-diagrams.nix
    # names this task by hand in its failure message, so the path from a
    # red check to the fix is explicit rather than implied by an aggregate.
    #
    # Writes in place rather than copying out of the store: it runs the
    # WORKING TREE's generator against the WORKING TREE's markdown, which
    # is what someone iterating on either one wants. The check is the half
    # that renders from tracked content.
    "generate:references:kimchi-surface" = {
      description = "Re-render the Kimchi surface reference diagrams";
      exec = ''
        ${bashPreamble}
        ${log}
        cd "$DEVENV_ROOT"
        log "Rendering Kimchi surface diagrams"
        ${kimchiSurfaceRenders.invocations {
          python3 = "${pkgs.python3}/bin/python3";
          script = "dev/skills/kimchi-surface-scan/scripts/surface-tables.py";
          markdown = "dev/references/kimchi-surface/kimchi-server-surface.md";
          outDir = "dev/references/kimchi-surface";
        }}
        log "Kimchi surface diagrams updated"
      '';
    };

    # `.#repo-contributing` and `.#repo-readme` are DIRECTORY outputs with
    # treefmt run inside the derivation, so the file copied out is already
    # formatted and a drift check can compare it against the tracked copy
    # without re-formatting first.
    "generate:repo:contributing" = {
      description = "Generate CONTRIBUTING.md from fragments and nix data";
      before = ["generate:repo"];
      exec = ''
        ${bashPreamble}
        ${log}
        ${copyOut}
        log "Building CONTRIBUTING.md"
        src=$(nix build .#repo-contributing --no-link --print-out-paths)
        copy_out "$src/CONTRIBUTING.md" CONTRIBUTING.md
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
        copy_out "$src/README.md" README.md
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

    # The instruction files are `ai.*`'s own read-only copies (dev/ai.nix
    # configures them); this aggregate only orders the two writers whose
    # files are COMMITTED, so `generate:all` refreshes every tracked file in
    # a worktree. It names no gitignored writer (Claude, Kiro), whose output
    # a worktree has no use for, and it is not a second writer: each file
    # still has exactly one.
    "generate:instructions" = {
      description = "Regenerate the committed instruction files (AGENTS.md, .github/)";
      after = [
        "ai:agents-md:materialize"
        "ai:copilot:materialize-instructions"
      ];
      exec = ''
        ${bashPreamble}
        ${log}
        log "Committed instruction files regenerated"
      '';
    };

    "generate:all" = {
      description = "Generate all content (instructions + repo)";
      after = [
        "generate:instructions"
        "generate:repo"
      ];
      exec = ''
        ${bashPreamble}
        ${log}
        log "All generation complete"
      '';
    };
  };
}
