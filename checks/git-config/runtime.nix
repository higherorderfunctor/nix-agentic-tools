# Runtime contracts of the `git.*` modules: real repositories, the real git,
# git-branchless and git-absorb this flake ships, and the devenv task bodies
# the modules render (which run lib/git-tool-settings/repo-config.sh, the same
# script a shell entry runs).
#
# Each check isolates itself: HOME and XDG_CONFIG_HOME in the build directory,
# GIT_CONFIG_NOSYSTEM set, GIT_CONFIG_GLOBAL unset. The user-global layer is
# written to $XDG_CONFIG_HOME/git/config — rendered from a Home Manager
# evaluation of the same `git.*` options, so Home Manager's lowering is under
# test too. It must be a file: git-branchless and git-absorb (libgit2) ignore
# GIT_CONFIG_GLOBAL, `git -c` and GIT_CONFIG_*.
#
# `enter <config> ROOT` runs what a devenv shell entry runs for that module
# configuration, in devenv's order: `git:branchless-init` (when
# git.branchless.enable), then `git:config`, then a hook installer when the
# fixture supplies one. `checks/git-config/module-eval.nix` asserts the real
# order in the task graph.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) evalDevenv evalHmModules;

  identity = {
    programs.git = {
      enable = true;
      settings.user = {
        email = "test@example.invalid";
        name = "Test";
      };
    };
  };

  # A user-global git config file, rendered by Home Manager from `git.*`.
  userGlobal = config:
    pkgs.writeText "user-global.gitconfig" (lib.generators.toGitINI
      (evalHmModules [{config = identity;} {inherit config;}]).config.programs.git.settings);

  # Shell running one module configuration's entry tasks, in devenv's order.
  entryTasks = config: let
    inherit ((evalDevenv config).config) tasks;
  in
    lib.concatMapStrings (name:
      lib.optionalString (tasks ? ${name}) ''
        DEVENV_ROOT="$root" ${lib.getExe pkgs.bash} -c ${lib.escapeShellArg tasks.${name}.exec}
      '') ["git:branchless-init" "git:config" "devenv:git-hooks:install"];

  # Repository-local settings every observation below reads through a
  # different program: git itself, git-branchless and git-absorb.
  natSettings = {
    git = {
      absorb.settings.fixupTargetAlwaysSHA = true;
      branchless.settings.revsets.alias.pick = "master";
      settings.merge.conflictStyle = "zdiff3";
    };
  };
  natWithInit = lib.recursiveUpdate natSettings {git.branchless.enable = true;};

  # mkRuntime NAME {configs; global} BODY: `configs` maps a label to a devenv
  # module configuration, and BODY calls `enter <label> ROOT`.
  mkRuntime = name: {
    configs,
    global ? {},
  }: body:
    pkgs.runCommand "git-config-${name}" {
      nativeBuildInputs = [
        pkgs.ai.gitTools.git-absorb
        pkgs.ai.gitTools.git-branchless
        pkgs.coreutils
        pkgs.git
        pkgs.gnugrep
      ];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      export HOME="$TMPDIR/home"
      export XDG_CONFIG_HOME="$HOME/.config"
      export GIT_CONFIG_NOSYSTEM=1
      unset GIT_CONFIG_GLOBAL
      mkdir -p "$XDG_CONFIG_HOME/git"

      use_global() {
        install -m 0644 "$1" "$XDG_CONFIG_HOME/git/config"
      }
      use_global ${userGlobal global}

      enter() {
        local label="$1" root="$2"
        case "$label" in
          ${lib.concatStrings (lib.mapAttrsToList (label: config: ''
          ${label})
            ${entryTasks config}
            ;;
        '')
        configs)}
          *)
            echo "no configuration labelled $label" >&2
            exit 1
            ;;
        esac
      }

      fail() {
        echo "FAIL: ${name}: $*" >&2
        exit 1
      }
      expect() {
        [ "$2" = "$3" ] || fail "$1: got '$2', want '$3'"
      }
      common_of() {
        git -C "$1" rev-parse --path-format=absolute --git-common-dir
      }
      last_entry() {
        git config --file "$(common_of "$1")/config" --null --list | tail -z -n 1 | tr -d '\0'
      }
      expect_nat_last() {
        expect "the NAT include is the last entry of the common config" \
          "$(last_entry "$1")" "include.path"$'\n'"nix-agentic-tools.gitconfig"
      }
      has_nat_include() {
        git config --file "$(common_of "$1")/config" --fixed-value \
          --get-all include.path nix-agentic-tools.gitconfig >/dev/null
      }
      commit() {
        printf '%s\n' "$3" >>"$1/$2"
        git -C "$1" add "$2"
        git -C "$1" commit -qm "$3"
      }
      # master: base; trunk: base + t1 — distinct commits for main() probes.
      two_trunks() {
        git init -q -b master "$1"
        commit "$1" f base
        git -C "$1" switch -qc trunk
        commit "$1" t t1
        git -C "$1" switch -q master
      }
      query() {
        git -C "$1" branchless query --raw "$2"
      }

      ${body}
      touch "$out"
    '';

  # scopedSync with a two-stack fixture: main advanced past the base of
  # stacks `a` and `b`, `a` checked out. `prepare` runs before the entry.
  scopedSync = name: prepare:
    mkRuntime "scoped-sync-${name}" {
      configs.synced.git.branchless = {
        enable = true;
        scopedSync = true;
      };
    } ''
      repo="$TMPDIR/repo"
      git init -q -b main "$repo"
      commit "$repo" f base
      git -C "$repo" switch -qc b
      commit "$repo" b b1
      git -C "$repo" switch -qc a main
      commit "$repo" a a1
      git -C "$repo" switch -q main
      commit "$repo" m m2
      git -C "$repo" switch -q a
      ${prepare}
      enter synced "$repo"
      expect "alias.sync" "$(git -C "$repo" config alias.sync)" "branchless sync 'stack()'"
      git -C "$repo" sync
      git -C "$repo" merge-base --is-ancestor main a || fail "bare git sync did not move the current stack"
      if git -C "$repo" merge-base --is-ancestor main b; then
        fail "bare git sync moved another stack"
      fi
    '';
in {
  checks = {
    # Per key, repository-local beats user-global for all three readers, and a
    # key the repository does not set falls through from user-global.
    git-config-repo-local-beats-user-global =
      mkRuntime "repo-local-beats-user-global" {
        configs.nat = natSettings;
        global.git = {
          absorb.settings = {
            fixupTargetAlwaysSHA = false;
            maxStack = 1;
          };
          branchless.settings.revsets.alias = {
            other = "trunk";
            pick = "trunk";
          };
          settings = {
            diff.algorithm = "patience";
            merge.conflictStyle = "diff3";
          };
        };
      } ''
        repo="$TMPDIR/repo"
        two_trunks "$repo"
        printf '1\n2\n3\n' >"$repo/f"
        git -C "$repo" commit -qam c1
        commit "$repo" g c2
        enter nat "$repo"

        # git
        expect "git merge.conflictStyle" "$(git -C "$repo" config merge.conflictStyle)" zdiff3
        expect "git diff.algorithm (user-global only)" "$(git -C "$repo" config diff.algorithm)" patience

        # git-branchless
        expect "branchless pick()" "$(query "$repo" 'pick()')" "$(git -C "$repo" rev-parse master)"
        expect "branchless other() (user-global only)" "$(query "$repo" 'other()')" "$(git -C "$repo" rev-parse trunk)"

        # git-absorb: absorb.maxStack = 1 (user-global only) hides c1, two
        # commits deep, so nothing is absorbed ...
        printf '1\nY\n3\n' >"$repo/f"
        git -C "$repo" add f
        (cd "$repo" && git absorb)
        expect "absorb maxStack from user-global" "$(git -C "$repo" rev-list --count HEAD)" 3
        git -C "$repo" restore --staged --worktree f
        # ... and absorb.fixupTargetAlwaysSHA = true (repository-local) names
        # the target by its SHA, not its subject.
        commit "$repo" h c3
        printf 'changed\n' >"$repo/h"
        git -C "$repo" add h
        (cd "$repo" && git absorb)
        expect "absorb fixupTargetAlwaysSHA from repo-local" \
          "$(git -C "$repo" log -1 --format=%s)" "fixup! $(git -C "$repo" rev-parse HEAD~1)"
      '';

    # The same value in both scopes observes exactly like the repository value
    # alone.
    git-config-identical-value-is-a-no-op =
      mkRuntime "identical-value-is-a-no-op" {
        configs.nat = natSettings;
      } ''
        repo="$TMPDIR/repo"
        two_trunks "$repo"
        enter nat "$repo"
        observe() {
          printf '%s|%s|%s\n' \
            "$(git -C "$repo" config merge.conflictStyle)" \
            "$(git -C "$repo" config absorb.fixupTargetAlwaysSHA)" \
            "$(query "$repo" 'pick()')"
        }
        alone="$(observe)"
        use_global ${userGlobal natSettings}
        expect "identical user-global value" "$(observe)" "$alone"
      '';

    # A typed main branch reaches `git branchless init` on a fresh repository,
    # where auto-detection would pick master.
    git-config-init-agrees-with-typed-main =
      mkRuntime "init-agrees-with-typed-main" {
        configs.trunk.git.branchless = {
          enable = true;
          settings.core.mainBranch = "trunk";
        };
      } ''
        repo="$TMPDIR/repo"
        two_trunks "$repo"
        enter trunk "$repo"
        expect "main() after the first entry" "$(query "$repo" 'main()')" "$(git -C "$repo" rev-parse trunk)"
        expect "branchless/config mainBranch" \
          "$(git config --file "$repo/.git/branchless/config" branchless.core.mainBranch)" trunk
        expect_nat_last "$repo"
      '';

    # The same result on a repository someone initialized first with another
    # main branch.
    git-config-order-independent-main =
      mkRuntime "order-independent-main" {
        configs.trunk.git.branchless = {
          enable = true;
          settings.core.mainBranch = "trunk";
        };
      } ''
        repo="$TMPDIR/repo"
        two_trunks "$repo"
        git -C "$repo" branchless init --main-branch master </dev/null
        expect "main() before entry" "$(query "$repo" 'main()')" "$(git -C "$repo" rev-parse master)"
        enter trunk "$repo"
        expect "main() after entry" "$(query "$repo" 'main()')" "$(git -C "$repo" rev-parse trunk)"
        expect_nat_last "$repo"
      '';

    # With no typed main branch, re-running init every entry keeps the main
    # branch the repository recorded instead of re-detecting it.
    git-config-reinit-keeps-recorded-main =
      mkRuntime "reinit-keeps-recorded-main" {
        configs.enabled.git.branchless.enable = true;
      } ''
        repo="$TMPDIR/repo"
        two_trunks "$repo"
        git -C "$repo" branchless init --main-branch trunk </dev/null
        enter enabled "$repo"
        enter enabled "$repo"
        expect "main() after two entries" "$(query "$repo" 'main()')" "$(git -C "$repo" rev-parse trunk)"
      '';

    # enabled → nothing → enabled observes as the first entry did; the empty
    # configuration removes the include and the file, and user-global shows
    # through.
    git-config-toggle-stable =
      mkRuntime "toggle-stable" {
        configs = {
          nat = natSettings;
          off = {};
        };
        global.git.settings.merge.conflictStyle = "diff3";
      } ''
        repo="$TMPDIR/repo"
        two_trunks "$repo"
        common="$(common_of "$repo")"
        enter nat "$repo"
        first="$(git -C "$repo" config merge.conflictStyle)|$(query "$repo" 'pick()')"
        expect "first entry" "$first" "zdiff3|$(git -C "$repo" rev-parse master)"

        enter off "$repo"
        if has_nat_include "$repo"; then
          fail "the include survived an empty configuration"
        fi
        [ ! -e "$common/nix-agentic-tools.gitconfig" ] || fail "the rendered file survived an empty configuration"
        expect "user-global after the toggle off" "$(git -C "$repo" config merge.conflictStyle)" diff3

        enter nat "$repo"
        expect "after the toggle back on" \
          "$(git -C "$repo" config merge.conflictStyle)|$(query "$repo" 'pick()')" "$first"
        expect_nat_last "$repo"
        [ "$(stat -c %a "$common/nix-agentic-tools.gitconfig")" = 444 ] || fail "the rendered file is not read-only"
      '';

    # A hand edit of a key NAT sets wins only until the next entry; a hand
    # edit of a key NAT does not set survives it. A section that already sat
    # above the include before the first entry loses too.
    git-config-nat-beats-hand-edits =
      mkRuntime "nat-beats-hand-edits" {
        configs.nat = natSettings;
      } ''
        above="$TMPDIR/above"
        two_trunks "$above"
        git -C "$above" config merge.conflictStyle merge
        enter nat "$above"
        expect "a section above the include" "$(git -C "$above" config merge.conflictStyle)" zdiff3

        # With no [merge] section in the repository config, `git config`
        # appends one after the include, so the edit wins until the next entry.
        repo="$TMPDIR/repo"
        two_trunks "$repo"
        enter nat "$repo"
        git -C "$repo" config merge.conflictStyle diff3
        git -C "$repo" config branchless.revsets.alias.pick trunk
        git -C "$repo" config diff.algorithm minimal
        expect "a hand edit before the next entry" "$(git -C "$repo" config merge.conflictStyle)" diff3
        expect "a branchless hand edit before the next entry" "$(query "$repo" 'pick()')" "$(git -C "$repo" rev-parse trunk)"

        enter nat "$repo"
        expect "git key NAT sets" "$(git -C "$repo" config merge.conflictStyle)" zdiff3
        expect "branchless key NAT sets" "$(query "$repo" 'pick()')" "$(git -C "$repo" rev-parse master)"
        expect "key NAT does not set" "$(git -C "$repo" config diff.algorithm)" minimal
        expect_nat_last "$repo"
        enter nat "$repo"
        expect_nat_last "$repo"
      '';

    # scopedSync on a fresh repository: init writes its own alias.sync, the
    # include after it wins, and bare `git sync` moves only the current stack.
    git-config-scoped-sync-fresh = scopedSync "fresh" "";

    # The same on a repository initialized before the first entry.
    git-config-scoped-sync-preinitialized =
      scopedSync "preinitialized" ''git -C "$repo" branchless init --main-branch main </dev/null'';

    # Unborn HEAD: init gets the symbolic HEAD as its explicit main branch.
    git-config-unborn-repository =
      mkRuntime "unborn-repository" {
        configs.nat = natWithInit;
      } ''
        repo="$TMPDIR/repo"
        git init -q -b main "$repo"
        enter nat "$repo"
        [ -f "$repo/.git/branchless/config" ] || fail "init did not run on an unborn repository"
        grep -F 'branchless' "$repo/.git/hooks/post-commit" >/dev/null || fail "no branchless post-commit hook"
        expect "branchless/config mainBranch" \
          "$(git config --file "$repo/.git/branchless/config" branchless.core.mainBranch)" main
        expect_nat_last "$repo"
        expect "git merge.conflictStyle" "$(git -C "$repo" config merge.conflictStyle)" zdiff3
      '';

    # A branchless directory without an initialization (a failed init, or any
    # earlier branchless command) does not stop the next init.
    git-config-guard-retries =
      mkRuntime "guard-retries" {
        configs.enabled.git.branchless.enable = true;
      } ''
        repo="$TMPDIR/repo"
        two_trunks "$repo"
        mkdir "$repo/.git/branchless"
        enter enabled "$repo"
        grep -F 'branchless' "$repo/.git/hooks/post-commit" >/dev/null || fail "no branchless post-commit hook"
        git config --file "$repo/.git/config" --fixed-value --get-all include.path branchless/config >/dev/null ||
          fail "no branchless/config include"
      '';

    # Entered from a linked worktree: the primary and a worktree added later
    # both see the configuration, and init targets the shared repository.
    git-config-linked-worktree =
      mkRuntime "linked-worktree" {
        configs.nat = natWithInit;
      } ''
        repo="$TMPDIR/repo"
        two_trunks "$repo"
        git -C "$repo" worktree add -q "$TMPDIR/first" -b first
        enter nat "$TMPDIR/first"
        git -C "$repo" worktree add -q "$TMPDIR/later" -b later
        for checkout in "$repo" "$TMPDIR/first" "$TMPDIR/later"; do
          expect "merge.conflictStyle in $checkout" "$(git -C "$checkout" config merge.conflictStyle)" zdiff3
          expect "pick() in $checkout" "$(query "$checkout" 'pick()')" "$(git -C "$repo" rev-parse master)"
        done
        [ -f "$repo/.git/branchless/config" ] || fail "init did not initialize the shared repository"
        expect_nat_last "$repo"
      '';

    # A bare primary with a linked worktree: init uses the primary HEAD.
    git-config-bare-primary =
      mkRuntime "bare-primary" {
        configs.nat = natWithInit;
      } ''
        two_trunks "$TMPDIR/source"
        git clone -q --bare "$TMPDIR/source" "$TMPDIR/bare.git"
        git -C "$TMPDIR/bare.git" worktree add -q "$TMPDIR/worktree" -b worktree
        enter nat "$TMPDIR/worktree"
        [ -f "$TMPDIR/bare.git/branchless/config" ] || fail "init did not run against a bare primary"
        grep -F 'branchless' "$TMPDIR/bare.git/hooks/post-commit" >/dev/null || fail "no branchless post-commit hook"
        expect "merge.conflictStyle in the worktree" "$(git -C "$TMPDIR/worktree" config merge.conflictStyle)" zdiff3
        expect_nat_last "$TMPDIR/worktree"
      '';

    # A failed init reports a retry command but returns success to devenv, so
    # the repository include and prek hook tasks still run.
    git-config-init-failure-keeps-dependents =
      mkRuntime "init-failure-keeps-dependents" {
        configs.failed = {
          inherit (natWithInit) git;
          tasks."devenv:git-hooks:install".exec = ''
            install -m 0755 ${pkgs.writeText "prek-pre-commit" ''
              #!/usr/bin/env bash
              set -euETo pipefail
              shopt -s inherit_errexit 2>/dev/null || :
              # installed by prek
            ''} "$DEVENV_ROOT/.git/hooks/pre-commit"
          '';
        };
      } ''
        repo="$TMPDIR/repo"
        two_trunks "$repo"
        mkdir -p "$repo/.git/branchless/config"
        enter failed "$repo" 2>"$TMPDIR/stderr"
        grep -F 'git branchless init failed' "$TMPDIR/stderr" >/dev/null || fail "no init failure message"
        grep -F "run by hand: git -C $repo branchless init" "$TMPDIR/stderr" >/dev/null || fail "no exact manual retry command"
        expect_nat_last "$repo"
        grep -F 'installed by prek' "$repo/.git/hooks/pre-commit" >/dev/null || fail "no prek pre-commit hook"
      '';

    # Reconciliation owns exactly its own include.path value: other includes
    # survive, and a git process holding config.lock fails the task rather
    # than losing either write.
    git-config-include-reconciliation =
      mkRuntime "include-reconciliation" {
        configs = {
          nat = natSettings;
          off = {};
        };
      } ''
        repo="$TMPDIR/repo"
        two_trunks "$repo"
        printf '[test]\n\tunrelated = true\n' >"$TMPDIR/unrelated.gitconfig"
        git -C "$repo" config --add include.path "$TMPDIR/unrelated.gitconfig"
        enter nat "$repo"
        enter nat "$repo"
        expect "one NAT include" \
          "$(git config --file "$repo/.git/config" --fixed-value --get-all include.path nix-agentic-tools.gitconfig)" \
          nix-agentic-tools.gitconfig
        expect "unrelated include" "$(git -C "$repo" config test.unrelated)" true

        enter off "$repo"
        expect "unrelated include after removal" "$(git -C "$repo" config test.unrelated)" true

        enter nat "$repo"
        git -C "$repo" config diff.algorithm minimal
        touch "$repo/.git/config.lock"
        if (enter nat "$repo"); then
          fail "moving the include ignored config.lock"
        fi
        if (enter off "$repo"); then
          fail "removing the include ignored config.lock"
        fi
        [ -e "$repo/.git/nix-agentic-tools.gitconfig" ] || fail "a failed removal still deleted the rendered file"
        rm "$repo/.git/config.lock"
      '';

    # Linked worktrees share the common config and branchless state. Paired
    # entries must serialize: the include and the rendered file agree after
    # every enable/disable race, and two first-time inits both succeed.
    git-config-common-state-concurrency =
      mkRuntime "common-state-concurrency" {
        configs = {
          nat = natWithInit;
          off = {};
        };
      } ''
        for iteration in $(seq 1 20); do
          # An enable racing a disable, entered from two linked worktrees.
          repo="$TMPDIR/race-$iteration"
          two_trunks "$repo"
          git -C "$repo" worktree add -q "$repo-first" -b first
          git -C "$repo" worktree add -q "$repo-second" -b second
          enter nat "$repo-first" &
          enable_pid="$!"
          enter off "$repo-second" &
          disable_pid="$!"
          wait "$enable_pid"
          wait "$disable_pid"
          include_present=false
          if has_nat_include "$repo"; then
            include_present=true
          fi
          file_present=false
          if [ -e "$repo/.git/nix-agentic-tools.gitconfig" ]; then
            file_present=true
          fi
          expect "include and file agree (iteration $iteration)" "$include_present" "$file_present"

          # Two first-time entries (two inits) at once.
          repo="$TMPDIR/init-$iteration"
          two_trunks "$repo"
          git -C "$repo" worktree add -q "$repo-first" -b first
          git -C "$repo" worktree add -q "$repo-second" -b second
          enter nat "$repo-first" &
          first_pid="$!"
          enter nat "$repo-second" &
          second_pid="$!"
          wait "$first_pid"
          wait "$second_pid"
          [ -f "$repo/.git/branchless/config" ] || fail "concurrent inits left no branchless/config (iteration $iteration)"
          expect_nat_last "$repo"
        done
      '';
  };
}
