# lib/worktree-session.nix — the worktree-session runner and its launch guard.
#
# The launch model this implements (sandbox-stack pivot, epic #1100): the
# devenv shell is entered in the PRIMARY CHECKOUT only, and the agent process
# starts with cwd = a linked worktree. devenv is NEVER activated in a worktree.
#
# That leaves a gap the runner exists to close. Every supported CLI anchors
# project-config discovery at cwd, but the artifacts it discovers there — the
# devenv `files.*` set (`.claude/settings.json`, `.mcp.json`, `.codex/*`,
# `.kiro/*`, `.pre-commit-config.yaml`, the materialized skill trees) and the
# gitignored generated projections (`CLAUDE.md`, `.claude/rules/`,
# `.kiro/steering/`) — exist only where a devenv shell has run. A fresh
# worktree has the tracked files and nothing else, so an agent launched there
# would silently run with no settings, no MCP, no skills and no rules.
#
# The prep contract is therefore machine-readable and derived, never hardcoded:
#
#   candidates = <primary>/.devenv/state/files.json .managedFiles      (devenv)
#              u dev/instructions.nix `destinations`                (projections)
#   copied     = the candidates `git check-ignore` reports as ignored
#
# Both sources propagate without a hand-kept list, but on different clocks: a
# new `files.*` entry is picked up at RUNTIME from files.json, while a new
# fragment category reaches `projections` only through a REBUILD of this
# derivation. warn_if_stale exists because of that asymmetry. The check-ignore
# filter is what makes copying safe: TRACKED projections (AGENTS.md,
# `.github/copilot-instructions.md`, `.github/instructions/*`, CONTRIBUTING.md,
# README.md) arrive with the checkout and must NOT be overwritten from the
# primary, or a dirty primary would leak uncommitted edits into every worktree.
#
# `--profile` is deliberately just an executable name. This file must not
# encode `ai.sandbox`'s option schema (#1103 owns that); the guard below is the
# seam a sandboxed profile wrapper calls, and the runner is a caller of
# whatever binary it is pointed at.
{
  lib,
  pkgs,
  # Working-tree destinations of the generated instruction projections —
  # `destinations` from dev/instructions.nix. Passed in rather than imported so
  # this file needs no treefmt-nix and stays cheap to evaluate.
  projections,
}: let
  shellStrict = import ../config/shell-strict.nix;

  # Absolute store paths rather than `runtimeInputs`. writeShellApplication
  # renders a non-empty runtimeInputs as `export PATH="<store paths>:$PATH"`,
  # and the runner launches an interactive agent session that would inherit it
  # — pinning a git different from the one the operator's shell provides, under
  # a tool whose whole job is running git workflows. With runtimeInputs empty
  # it emits `export PATH="$PATH"` instead: a no-op for the child's PATH, which
  # is the point, though under `nounset` it does mean a PATH-less invocation
  # dies on that line rather than proceeding. Failing there is the correct
  # outcome — every tool this script needs is referenced by absolute store
  # path, but the profile binary it launches is resolved from PATH.
  cu = "${pkgs.coreutils}/bin";
  jq = "${pkgs.jq}/bin/jq";

  # git, with the three environment variables that would otherwise decide the
  # answer stripped. This is load-bearing for the guard, not hygiene:
  # `rev-parse --git-dir` reports whatever `$GIT_DIR` names rather than what
  # `-C <dir>` names, so with `GIT_DIR=<primary>/.git/worktrees/<slug>` exported
  # the guard answered "linked worktree" while cwd was the PRIMARY CHECKOUT and
  # exited 0 — measured 2026-08-18. Git hooks run with GIT_DIR exported, so a
  # launch chain passing through one is a real vector, and the same override
  # would skew the runner's worktrees_root onto the wrong repository.
  git = "${cu}/env -u GIT_DIR -u GIT_COMMON_DIR -u GIT_WORK_TREE ${pkgs.git}/bin/git";

  mkApp = name: text:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [];
      extraShellCheckFlags = shellStrict.shellcheckFlags;
      inherit (shellStrict) bashOptions;
      text = "${shellStrict.shoptHeader}\n${text}";
    };

  # No heredocs anywhere below. A quoted heredoc's terminator must sit at
  # column 0 after Nix strips the indented string's common indentation, which
  # makes it hostage to how alejandra chooses to reindent this file. printf
  # with one argument per line survives any reformatting.
  guard = mkApp "ai-workspace-guard" ''
    # Refuse to launch a workspace-profile binary from the primary checkout.
    #
    # The workspace profile's `git-worktree` combinator rw-binds $PWD. Launched
    # in a linked worktree that is the intent: the worktree is writable and the
    # primary checkout is remounted read-only over it. Launched in the PRIMARY
    # checkout the same bind makes the operator's own checkout writable to the
    # agent — the one thing the topology exists to prevent — and it fails open,
    # because nothing about the resulting session looks wrong.
    #
    # Discriminator: `--git-dir` equals `--git-common-dir` in the primary
    # checkout and differs in every linked worktree (`<common>/worktrees/<name>`),
    # including from a subdirectory of either. Both are asked for with
    # --path-format=absolute because a bare `rev-parse --git-dir` answers a path
    # RELATIVE to cwd when it can — at the top of the primary checkout that is
    # the bare string `.git`, which is not comparable with the absolute answer
    # the linked case returns.
    #
    # Fails CLOSED: no repository, or a bare one, is a refusal, not a pass.
    # #1103's profile wrappers invoke this as their first act; the runner
    # invokes it too, so a mis-wired wrapper is still caught.
    die() {
      printf 'ai-workspace-guard: %s\n' "$1" >&2
      exit 1
    }

    usage() {
      printf '%s\n' \
        'usage: ai-workspace-guard [DIR]' \
        "" \
        "Exits 0 when DIR (default: \$PWD) is inside a LINKED git worktree, and" \
        'non-zero — with a diagnostic on stderr — when it is inside the primary' \
        'checkout, inside a bare repository, or not in a git working tree at all.' \
        "" \
        'Intended as the first line of a sandbox profile wrapper whose bind' \
        "policy makes \$PWD writable."
    }

    dir="$PWD"
    case "''${1-}" in
      -h | --help)
        usage
        exit 0
        ;;
      # `--` ends option parsing, so a directory whose name starts with `-`
      # stays reachable.
      --)
        shift
        ;;
      -*) die "unknown option: $1" ;;
      *) ;;
    esac
    [ "$#" -le 1 ] || die "expected at most one DIR argument"
    [ "$#" -eq 0 ] || dir="$1"

    if ! git_dir="$(${git} -C "$dir" rev-parse --path-format=absolute --git-dir 2>/dev/null)"; then
      die "refusing to launch: '$dir' is not inside a git working tree. A workspace profile rw-binds \$PWD; it must be a linked worktree."
    fi

    if [ "$(${git} -C "$dir" rev-parse --is-bare-repository)" = "true" ]; then
      die "refusing to launch: '$dir' is inside a bare repository, which has no working tree to bind."
    fi

    common_dir="$(${git} -C "$dir" rev-parse --path-format=absolute --git-common-dir)"

    if [ "$git_dir" = "$common_dir" ]; then
      primary="$(${cu}/dirname "$common_dir")"
      printf '%s\n' \
        'ai-workspace-guard: refusing to launch a workspace profile from the PRIMARY CHECKOUT.' \
        "  cwd:     $dir" \
        "  primary: $primary" \
        "" \
        "A workspace profile rw-binds \$PWD, so launching here would make the" \
        "operator's own checkout writable to the agent. Launch from a linked" \
        'worktree instead:' \
        "" \
        '  ai-worktree-session run <slug>' \
        "" \
        "(An unsandboxed profile does not bind \$PWD and is not guarded.)" >&2
      exit 1
    fi
  '';

  runner = mkApp "ai-worktree-session" ''
    # The generated instruction projections, baked from dev/instructions.nix
    # `destinations` at build time. Only the gitignored subset is copied; see
    # resolve_paths.
    PROJECTIONS=(${lib.concatMapStringsSep " " lib.escapeShellArg projections})

    prog="ai-worktree-session"

    # Repository geometry, resolved once by resolve_repo.
    primary=""
    common_dir=""
    worktrees_root=""
    # The prep contract, resolved once by resolve_paths. Newline-separated.
    managed_paths=""
    projection_paths=""
    prep_paths=""
    # Flags shared by the subcommands that prep.
    allow_missing=0
    keep=0

    die() {
      printf '%s: %s\n' "$prog" "$1" >&2
      exit 1
    }

    note() { printf '%s: %s\n' "$prog" "$1" >&2; }

    usage() {
      printf '%s\n' \
        'usage:' \
        '  ai-worktree-session run [OPTIONS] <slug> [-- COMMAND [ARG...]]' \
        '  ai-worktree-session prep [--allow-missing] <worktree-path>' \
        '  ai-worktree-session prep-list [--json]' \
        '  ai-worktree-session remove [--force] <slug|path>' \
        "" \
        'run        create the worktree, prep it from the primary checkout,' \
        '           launch the profile binary with cwd = the worktree, clean up.' \
        'prep       (re-)prep an already existing worktree and exit.' \
        'prep-list  print the prep contract — one repository-relative path per' \
        '           line, or a JSON object with per-source provenance under' \
        '           --json. This is the documented output consumers build on.' \
        'remove     tear the worktree down. The branch is deliberately left.' \
        "" \
        'run options:' \
        '  --type <type>    conventional-commits type for a derived branch name' \
        '                   (default: feat) — the branch becomes <type>/<slug>' \
        '  --branch <name>  explicit branch name, overriding --type' \
        '  --base <ref>     base for a newly created branch (default: origin/main)' \
        "  --profile <bin>  executable to launch (default: \$AI_WORKTREE_PROFILE," \
        '                   else "claude"). Just a name — this runner does not' \
        '                   know what sandbox profiles exist.' \
        '  --reuse          attach to the existing worktree/branch for <slug>' \
        '  --keep           never remove the worktree on exit' \
        '  --allow-missing  downgrade a missing prep source to a warning' \
        "" \
        'A "--" separator replaces the profile entirely: everything after it is' \
        'the argv of the command to run in the worktree.' \
        "" \
        'Cleanup on exit removes the worktree only when that is provably' \
        'lossless. "git worktree remove" refuses a tree with modified or' \
        'untracked files (it deletes ignored files, so the prepped artifacts are' \
        'not an obstacle), and the runner additionally holds on to any worktree' \
        'whose HEAD carries commits that are on no remote, or whose command' \
        'exited non-zero. Anything held is named on stderr with the command to' \
        'remove it.' >&2
    }

    # ── Repository geometry ──────────────────────────────────────────────
    # Resolved from cwd, so the runner works from the primary checkout (the
    # normal case: it is launched from the devenv shell there) or from any
    # worktree.
    resolve_repo() {
      common_dir="$(${git} rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
        die "not inside a git repository — run this from the primary checkout."
      primary="$(${cu}/dirname "$common_dir")"
      # Worktrees live in a sibling of the primary checkout. Derived from the
      # COMMON dir so the answer is identical whichever worktree resolves it; a
      # relative "../<repo>-worktrees" would resolve one level too deep when run
      # from inside a linked worktree.
      worktrees_root="''${primary}-worktrees"
    }

    # ── The prep contract ────────────────────────────────────────────────
    resolve_paths() {
      local files_json candidates rc out
      files_json="$primary/.devenv/state/files.json"

      [ -f "$files_json" ] ||
        die "$files_json is missing. It is written by a devenv shell entry in the primary checkout, which is the only thing that materializes the files.* artifact set. Run 'devenv shell true' in $primary and retry."

      # Three separate checks so each diagnostic names the actual defect. One
      # combined `jq -e` would report every malformed-JSON failure as the
      # newline case, which is the rarest of the three.
      ${jq} -e . "$files_json" > /dev/null 2>&1 ||
        die "$files_json is not valid JSON."
      ${jq} -e 'has("managedFiles") and (.managedFiles | type == "array")' "$files_json" > /dev/null ||
        die "$files_json has no .managedFiles array."
      # Paths are handed to git one per line, so an embedded newline would
      # silently split into two bogus paths. Reject rather than mis-copy. (No
      # current entry contains one; the baked PROJECTIONS cannot.)
      ${jq} -e 'all(.managedFiles[]; test("\n") | not)' "$files_json" > /dev/null ||
        die "$files_json contains a managed path with an embedded newline, which this contract cannot express."

      managed_paths="$(${jq} -r '.managedFiles[]' "$files_json")" ||
        die "could not read .managedFiles from $files_json"

      projection_paths="$(printf '%s\n' "''${PROJECTIONS[@]}")"

      candidates="$(printf '%s\n%s\n' "$managed_paths" "$projection_paths" | ${cu}/sort -u)"

      # `check-ignore --stdin` prints only the ignored inputs and exits 1 when
      # none matched — an ordinary outcome, not a failure — so exit 1 is
      # accepted and anything above it is not.
      # -c core.quotePath=false: with the default on, git C-quotes any path
      # holding a non-ASCII byte, and the quoted form would round-trip as a
      # path that does not exist.
      set +e
      out="$(printf '%s\n' "$candidates" | ${git} -C "$primary" -c core.quotePath=false check-ignore --stdin)"
      rc=$?
      set -e
      [ "$rc" -le 1 ] || die "git check-ignore failed (exit $rc) in $primary"

      prep_paths="$out"
      [ -n "$prep_paths" ] ||
        die "the prep contract resolved to zero paths, which cannot be right — check that $primary has a materialized devenv state."
    }

    # A worktree may be prepped only if it is a LINKED worktree of this repo.
    # Prepping the primary would overwrite its live devenv artifacts with copies
    # of themselves; prepping an unrelated directory would scatter this
    # repository's config into it.
    assert_linked_worktree() {
      local target="$1" tgt_git tgt_common
      tgt_git="$(${git} -C "$target" rev-parse --path-format=absolute --git-dir 2>/dev/null)" ||
        die "$target is not a git working tree"
      tgt_common="$(${git} -C "$target" rev-parse --path-format=absolute --git-common-dir)"
      [ "$tgt_common" = "$common_dir" ] ||
        die "$target belongs to a different repository ($tgt_common)"
      [ "$tgt_git" != "$tgt_common" ] ||
        die "$target IS the primary checkout — prep targets linked worktrees only."
    }

    # Every prep source must exist in the primary checkout. Split out of
    # do_prep and called BEFORE a worktree is created, because `die` bypasses
    # cleanup: failing after `git worktree add` would strand the worktree and
    # the branch, and the obvious retry then fails with "already exists".
    assert_sources_present() {
      local rel
      local -a missing=()
      while IFS= read -r rel; do
        [ -e "$primary/$rel" ] || [ -L "$primary/$rel" ] || missing+=("$rel")
      done <<< "$prep_paths"

      [ "''${#missing[@]}" -gt 0 ] || return 0

      note "the following prep sources are missing from $primary:"
      printf '  %s\n' "''${missing[@]}" >&2
      if [ "$allow_missing" -eq 0 ]; then
        die "refusing to prep an incomplete worktree — an agent launched there would silently lose that config. Regenerate in the primary checkout ('devenv shell true', then 'devenv tasks run --mode before generate:all'), or pass --allow-missing."
      fi
      note "continuing anyway (--allow-missing)"
    }

    # Warn when the primary holds generated projections this binary does not
    # know about. PROJECTIONS is baked at build time, so an installed runner
    # older than the fragment registry would silently omit every rule added
    # since — the exact silent-missing-config failure this tool exists to
    # close, and invisible without a check.
    #
    # The directories to scan are derived from PROJECTIONS itself, never
    # hardcoded: any directory a projection lands in (the repository root
    # excepted, which holds unrelated ignored files) is wholly generator-owned.
    # Only IGNORED strays are reported; a tracked extra is not this tool's
    # business. A warning, not an error — a stale runner still works for
    # everything it does know about.
    warn_if_stale() {
      local rel dir entry
      local -A known=() dirs=()
      local -a strays=()

      for rel in "''${PROJECTIONS[@]}"; do
        known["$rel"]=1
        dir="$(${cu}/dirname "$rel")"
        [ "$dir" = "." ] || dirs["$dir"]=1
      done

      for dir in "''${!dirs[@]}"; do
        [ -d "$primary/$dir" ] || continue
        for entry in "$primary/$dir"/*; do
          [ -e "$entry" ] || continue
          rel="$dir/$(${cu}/basename "$entry")"
          [ -z "''${known[$rel]-}" ] || continue
          ${git} -C "$primary" check-ignore -q "$rel" || continue
          strays+=("$rel")
        done
      done

      [ "''${#strays[@]}" -gt 0 ] || return 0
      note "WARNING: $primary holds generated projections this ai-worktree-session does not know about:"
      printf '  %s\n' "''${strays[@]}" >&2
      note "they will NOT be prepped. Rebuild the runner (nix build .#ai-worktree-session) so its baked projection list matches the fragment registry."
    }

    # Copy the resolved contract from the primary checkout into $1.
    #
    # Entries are copied one at a time with `cp -PR`: today every files.json
    # entry is a symlink into the store, some of them to DIRECTORIES (the
    # materialized skill trees), and -P copies the link itself rather than
    # dereferencing a read-only store tree into the worktree. -R covers a real
    # directory should one ever appear. The destination is unlinked first so a
    # re-prep replaces a symlink instead of writing THROUGH it into the store.
    #
    # Re-prep PRUNES. The previous run's contract is recorded in the worktree's
    # private git admin directory (so it is removed with the worktree and never
    # visible to git status), and anything in it that has left the contract is
    # deleted. Without this, a fragment category removed upstream leaves its
    # `.claude/rules/<x>.md` behind in every reused worktree and the agent goes
    # on loading a rule the repository retired — worse than a missing one.
    # Pruning only ever touches paths this tool previously wrote.
    do_prep() {
      local target="$1" rel src dst manifest
      manifest="$(${git} -C "$target" rev-parse --path-format=absolute --git-dir)/ai-worktree-session-prep.list"

      local -A wanted=()
      while IFS= read -r rel; do wanted["$rel"]=1; done <<< "$prep_paths"

      local pruned=0
      if [ -f "$manifest" ]; then
        while IFS= read -r rel; do
          [ -n "$rel" ] || continue
          [ -z "''${wanted[$rel]-}" ] || continue
          # Defensive: a manifest is written by this tool, but never let one
          # reach outside the worktree.
          case "$rel" in
            /* | *..*) continue ;;
            *) ;;
          esac
          [ -e "$target/$rel" ] || [ -L "$target/$rel" ] || continue
          # ''${x:?} so an empty target or rel can never expand to `/`.
          ${cu}/rm -rf -- "''${target:?}/''${rel:?}"
          pruned=$((pruned + 1))
        done < "$manifest"
      fi

      local copied=0
      while IFS= read -r rel; do
        src="$primary/$rel"
        [ -e "$src" ] || [ -L "$src" ] || continue
        dst="$target/$rel"
        ${cu}/mkdir -p "$(${cu}/dirname "$dst")"
        ${cu}/rm -rf -- "$dst"
        ${cu}/cp -PR -- "$src" "$dst"
        copied=$((copied + 1))
      done <<< "$prep_paths"

      printf '%s\n' "$prep_paths" > "$manifest"

      if [ "$pruned" -gt 0 ]; then
        note "prepped $copied paths into $target ($pruned stale path(s) pruned)"
      else
        note "prepped $copied paths into $target"
      fi
    }

    cmd_prep_list() {
      local json=0
      case "''${1-}" in
        --json) json=1 ;;
        "") : ;;
        *) die "prep-list: unknown option: $1" ;;
      esac
      resolve_repo
      resolve_paths
      if [ "$json" -eq 1 ]; then
        ${jq} -n \
          --arg primary "$primary" \
          --arg managed "$managed_paths" \
          --arg projections "$projection_paths" \
          --arg prep "$prep_paths" \
          '{
             primary: $primary,
             paths: ($prep | split("\n")),
             sources: {
               filesJson: ($managed | split("\n")),
               projections: ($projections | split("\n"))
             }
           }'
      else
        printf '%s\n' "$prep_paths"
      fi
    }

    cmd_prep() {
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --allow-missing)
            allow_missing=1
            shift
            ;;
          -*) die "prep: unknown option: $1" ;;
          *) break ;;
        esac
      done
      [ "$#" -eq 1 ] || die "prep: expected exactly one worktree path"
      resolve_repo
      local target
      target="$(${cu}/realpath "$1")"
      assert_linked_worktree "$target"
      resolve_paths
      warn_if_stale
      assert_sources_present
      do_prep "$target"
    }

    cmd_remove() {
      local -a force=()
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --force)
            force=(--force)
            shift
            ;;
          -*) die "remove: unknown option: $1" ;;
          *) break ;;
        esac
      done
      [ "$#" -eq 1 ] || die "remove: expected exactly one slug or path"
      resolve_repo
      local target="$1"
      case "$target" in
        */*) target="$(${cu}/realpath "$target")" ;;
        *) target="$worktrees_root/$target" ;;
      esac
      [ -d "$target" ] || die "no such worktree: $target"
      assert_linked_worktree "$target"
      ${git} -C "$primary" worktree remove "''${force[@]}" "$target"
      ${git} -C "$primary" worktree prune
      note "removed $target (the branch was left in place)"
    }

    # Remove the worktree only when doing so provably loses nothing.
    #
    # `git worktree remove` is the safety mechanism, not a formality: it deletes
    # ignored files (so the prepped artifacts never block it) and REFUSES a tree
    # holding modified or untracked files. On top of that, commits that exist on
    # no remote are treated as work in progress — a checkout is cheap to
    # recreate, an unpushed branch tip is not worth the ambiguity.
    cleanup() {
      local target="$1" status="$2" slug unpushed
      slug="$(${cu}/basename "$target")"
      if [ "$keep" -eq 1 ]; then
        note "keeping $target (--keep)"
        return 0
      fi
      if [ "$status" -ne 0 ]; then
        note "command exited $status — keeping $target so the state is inspectable"
        note "remove it with: $prog remove $slug"
        return 0
      fi
      unpushed="$(${git} -C "$target" rev-list --count HEAD --not --remotes)"
      if [ "$unpushed" -ne 0 ]; then
        note "keeping $target — HEAD carries $unpushed commit(s) that are on no remote"
        note "push the branch, then: $prog remove $slug"
        return 0
      fi
      local err
      if err="$(${git} -C "$primary" worktree remove "$target" 2>&1)"; then
        ${git} -C "$primary" worktree prune
        note "removed $target (the branch was left in place)"
      else
        # Report what git actually said. The usual cause is modified or
        # untracked files, but a lock or a permission problem lands here too
        # and a hardcoded diagnosis would send the operator after the wrong
        # thing — and recommend --force, which would not help.
        note "keeping $target — git worktree remove refused: $err"
        note "if the tree holds only work you do not want, remove it with: $prog remove --force $slug"
      fi
    }

    cmd_run() {
      local type="feat" branch="" base="origin/main" profile="" reuse=0 slug=""
      local -a cmdline=()

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --type)
            type="''${2:?--type needs a value}"
            shift 2
            ;;
          --branch)
            branch="''${2:?--branch needs a value}"
            shift 2
            ;;
          --base)
            base="''${2:?--base needs a value}"
            shift 2
            ;;
          --profile)
            profile="''${2:?--profile needs a value}"
            shift 2
            ;;
          --reuse)
            reuse=1
            shift
            ;;
          --keep)
            keep=1
            shift
            ;;
          --allow-missing)
            allow_missing=1
            shift
            ;;
          --)
            shift
            cmdline=("$@")
            break
            ;;
          -*) die "run: unknown option: $1" ;;
          *)
            [ -z "$slug" ] || die "run: unexpected argument: $1"
            slug="$1"
            shift
            ;;
        esac
      done

      if [ -z "$slug" ]; then
        usage
        die "run: a <slug> is required"
      fi
      case "$slug" in
        */* | .*) die "run: '$slug' is not a usable worktree slug" ;;
        *) ;;
      esac

      if [ "''${#cmdline[@]}" -eq 0 ]; then
        [ -n "$profile" ] || profile="''${AI_WORKTREE_PROFILE:-claude}"
        cmdline=("$profile")
      fi
      command -v "''${cmdline[0]}" > /dev/null ||
        die "''${cmdline[0]} is not on PATH. Point --profile at an installed profile binary, or set \$AI_WORKTREE_PROFILE."

      resolve_repo

      # Resolve and validate the contract BEFORE creating anything. Both steps
      # are independent of the target, and `die` bypasses cleanup — failing
      # after `git worktree add` would strand a worktree and a branch that the
      # obvious retry then refuses to reuse.
      resolve_paths
      warn_if_stale
      assert_sources_present

      [ -n "$branch" ] || branch="$type/$slug"
      local target="$worktrees_root/$slug"

      if [ -e "$target" ]; then
        [ "$reuse" -eq 1 ] ||
          die "$target already exists. Pass --reuse to attach to it, or pick another slug."
        assert_linked_worktree "$target"
        note "reusing $target"
      elif ${git} -C "$primary" show-ref --verify --quiet "refs/heads/$branch"; then
        [ "$reuse" -eq 1 ] ||
          die "branch '$branch' already exists but has no worktree at $target. Pass --reuse to check it out there, or pick another slug."
        ${cu}/mkdir -p "$worktrees_root"
        ${git} -C "$primary" worktree add "$target" "$branch"
      else
        ${cu}/mkdir -p "$worktrees_root"
        ${git} -C "$primary" worktree add -b "$branch" "$target" "$base"
      fi

      do_prep "$target"

      # Defense in depth. #1103's profile wrapper runs the same guard; running
      # it here too means a mis-wired wrapper still cannot start in the primary.
      ${guard}/bin/ai-workspace-guard "$target"

      local status=0
      (cd "$target" && "''${cmdline[@]}") || status=$?
      cleanup "$target" "$status"
      return "$status"
    }

    case "''${1-}" in
      run)
        shift
        cmd_run "$@"
        ;;
      prep)
        shift
        cmd_prep "$@"
        ;;
      prep-list)
        shift
        cmd_prep_list "$@"
        ;;
      remove)
        shift
        cmd_remove "$@"
        ;;
      -h | --help | help) usage ;;
      "")
        usage
        exit 1
        ;;
      *)
        usage
        die "unknown subcommand: $1"
        ;;
    esac
  '';
in {
  inherit guard runner;
}
