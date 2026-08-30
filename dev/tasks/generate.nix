# dev/tasks/generate.nix — Content generation devenv tasks.
{
  pkgs,
  instr,
  ...
}: let
  materializeInstructions = import ../../lib/materialize-repo-instructions.nix {inherit instr pkgs;};
  materialize = group: ''
    ${bashPreamble}
    exec ${pkgs.lib.getExe materializeInstructions} ${group} "$DEVENV_ROOT"
  '';
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

    # `.#repo-contributing` and `.#repo-readme` are DIRECTORY outputs, the
    # same shape as `instructions-*`: treefmt runs inside the derivation,
    # so the file copied out is already formatted and a drift check can
    # compare it against the tracked copy without re-formatting first.
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

    "generate:instructions:agents" = {
      description = "Generate AGENTS.md from fragments";
      before = ["generate:instructions"];
      exec = materialize "agents";
    };

    "generate:instructions:claude" = {
      description = "Generate CLAUDE.md and Claude rule files from fragments";
      before = ["generate:instructions"];
      exec = materialize "claude";
    };

    "generate:instructions:copilot" = {
      description = "Generate Copilot instruction files from fragments";
      before = ["generate:instructions"];
      exec = materialize "copilot";
    };

    "generate:instructions:kiro" = {
      description = "Generate Kiro steering files from fragments";
      before = ["generate:instructions"];
      exec = materialize "kiro";
    };

    # ── Bootstrap ────────────────────────────────────────────────────
    # Runs on every `devenv shell`, `direnv reload`, `devenv up`,
    # `devenv reload` and manual `devenv test`. THIS is what replaces the
    # deleted devenv `files.*` block: a fresh clone has no CLAUDE.md,
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
      exec = materialize "all";
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

    # ── The typed `.sgra` grammar surface (SLICE-GRAMMAR-FROM-NIX) ──────
    #
    # Two GENERATED files, in a fixed order: `extract.py` reads strictdoc's own
    # grammar and writes faithful.nix; `normalize.py` reads faithful.nix and
    # writes normalized.nix. Running the second against a stale first produces a
    # surface derived from a grammar nobody is running, so the edge below is
    # load-bearing rather than tidiness.
    #
    # NOT in `generate:all`, and deliberately: `strictdoc-grammar-extract` is
    # interactive-only (devenv.nix sets `ai.strictdoc.enable = !isCI`, and that
    # module is what puts the runner on PATH), so an aggregate that reached it
    # would fail in CI on a missing binary. Milestone 1 is locally invoked and
    # wires no CI.
    #
    # `docs/sdoc/grammar.sgra` is not written here either, and that is now an
    # ORDERING constraint rather than the open question it used to be. The
    # operator ruled 2026-08-27 that every `.sgra` in this repository is
    # generated (MECH-GRAMMAR-SGRA-NOT-GENERATED); the `ai.strictdoc` devenv
    # module writes them, from its own `generate:sgra` task.
    #
    # That task is a SEPARATE INVOCATION on purpose. The rendered bytes are an
    # evaluation-time value and devenv fixes every task's script before running
    # any of them, so a `generate:sgra` chained into this run would write the
    # grammar rendered from the normalized surface that existed when the run
    # began — silently, in exactly the run that regenerated it. See
    # packages/strictdoc-grammar/modules/devenv/default.nix.
    "generate:sdoc-grammar:faithful" = {
      description = "Extract the faithful .sgra surface from strictdoc's own grammar";
      before = ["generate:sdoc-grammar:normalized"];
      exec = ''
        ${bashPreamble}
        ${log}
        cd "$DEVENV_ROOT"
        log "Extracting packages/strictdoc-grammar/lib/faithful.nix"
        strictdoc-grammar-extract packages/strictdoc-grammar/extract/extract.py \
          --output packages/strictdoc-grammar/lib/faithful.nix
      '';
    };

    "generate:sdoc-grammar:normalized" = {
      description = "Normalize the faithful .sgra surface into typed nodes plus encoders";
      before = ["generate:sdoc-grammar"];
      exec = ''
        ${bashPreamble}
        ${log}
        cd "$DEVENV_ROOT"
        log "Normalizing packages/strictdoc-grammar/lib/normalized.nix"
        strictdoc-grammar-extract packages/strictdoc-grammar/extract/normalize.py
      '';
    };

    "generate:sdoc-grammar" = {
      description = "Generate the typed .sgra grammar surface (faithful + normalized)";
      after = [
        "generate:sdoc-grammar:faithful"
        "generate:sdoc-grammar:normalized"
      ];
      exec = ''
        ${bashPreamble}
        ${log}
        # No backticks in this message: the exec body is bash, and a backtick
        # pair here really did run the check task as a command substitution.
        log "Grammar surface generated. Next, in a FRESH invocation each:"
        log "  devenv tasks run generate:sgra      (write the .sgra files)"
        log "  devenv tasks run check:sdoc-grammar (gate the result)"
      '';
    };

    # ── The whiteboard view (MECH-VIEW-TASK) ─────────────────────────
    #
    # Renders one root narrative: strictdoc export into a CLEAN directory
    # (an incremental export can exit 0 on a broken input -- see the sdoc
    # skill), then view-check, wireline and render from docs/sdoc/view/.
    # The page and the payload land under output/view/, which is gitignored:
    # the canon is the source and the page is regenerable.
    #
    # The root comes in through devenv's task-input channel, because
    # `devenv tasks run` accepts no `--` passthrough (measured 2026-08-30:
    # a `-- --root X` is read as a task named `--root`):
    #
    #   devenv tasks run --mode before view:render --input root=NAR-SEMANTIC-LAYER
    #
    # A view-check FINDING (exit 1) does not stop the render: the findings
    # are embedded in the payload and listed on the start screen, which is
    # where a reader is meant to see them. A bad root (exit 2) does.
    #
    # PYTHONPATH and STRICTDOC_CACHE_DIR are unset for the same reason the
    # sdoc skill's recipes unset them: a shell-level PYTHONPATH shadows the
    # interpreter under test, and the cache dir would redirect the export.
    "view:render" = {
      description = "Render one root narrative: export, view-check, wireline, render";
      exec = ''
        ${bashPreamble}
        ${log}
        cd "$DEVENV_ROOT"
        root=$(printf '%s' "''${DEVENV_TASK_INPUT:-null}" | jq -r '.root // empty')
        if [ -z "$root" ]; then
          echo "view:render: no root. Run: devenv tasks run --mode before view:render --input root=UID" >&2
          exit 2
        fi
        view=docs/sdoc/view
        out=output/view
        export_dir="$out/export"
        rm -rf "$export_dir"
        mkdir -p "$out"
        slug=$(printf '%s' "$root" | tr '[:upper:]' '[:lower:]')
        log "Exporting the canon into $export_dir"
        env -u PYTHONPATH -u STRICTDOC_CACHE_DIR strictdoc export . --formats=json --output-dir "$export_dir" >/dev/null
        index="$export_dir/json/index.json"
        log "Checking the tree under $root"
        rc=0
        # To stderr: devenv shows a task's stderr in its summary and hides stdout.
        env -u PYTHONPATH python3 "$view/view-check.py" "$index" . --root "$root" >&2 || rc=$?
        if [ "$rc" -gt 1 ]; then exit "$rc"; fi
        log "Writing the payload and the page"
        env -u PYTHONPATH python3 "$view/wireline.py" "$index" . --root "$root" --out "$out/$slug.json"
        env -u PYTHONPATH python3 "$view/render.py" "$out/$slug.json" "$view/template.html" --out "$out/$slug.html" >/dev/null
        log "wrote $out/$slug.html"
        log "wrote $out/$slug.json"
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
