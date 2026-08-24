# Black-box contracts for the exact Beads and Dolt packages used by the MVP.
#
# These assertions deliberately include surprising upstream behavior that the
# module must defend against. If a future package fixes one, this check should
# fail so the lifecycle and reference can be simplified from fresh evidence.
{pkgs, ...}: let
  inherit (pkgs) beads;
  qualifiedBeads = pkgs.ai.devTools.beads;
  inherit (qualifiedBeads) dolt;
  vu = import ../overlays/lib.nix;
in
  pkgs.runCommandLocal "beads-contracts-check" {
    nativeBuildInputs = [
      qualifiedBeads
      dolt
      beads
      pkgs.coreutils
      pkgs.findutils
      pkgs.git
      pkgs.gnugrep
      pkgs.jq
    ];
  } ''
    fail() {
      printf 'beads-contracts: %s\n' "$1" >&2
      exit 1
    }

    expect_eq() {
      local label="$1" want="$2" got="$3"
      [ "$got" = "$want" ] || fail "$label: want [$want], got [$got]"
    }

    make_home() {
      local root="$1"
      mkdir -p "$root/home/.cache" "$root/home/.config" "$root/home/.local/share"
      chmod 700 "$root/home"
    }

    make_state() {
      local state="$1"
      mkdir -p "$state"
      chmod 700 "$state"
      cat > "$state/config.yaml" <<'YAML'
    no-git-ops: true
    YAML
      chmod 600 "$state/config.yaml"
    }

    snapshot_hooks() {
      local hook hooks="$1" output="$2"
      find "$hooks" -mindepth 1 -maxdepth 1 \
        -printf 'entry|%y|%m|%f|%l\n' | sort > "$output"
      while IFS= read -r hook; do
        printf 'sha256|%s|' "$hook" >> "$output"
        sha256sum "$hooks/$hook" | cut -d' ' -f1 >> "$output"
      done < <(find "$hooks" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)
    }

    assert_bare_cache() {
      local cache forbidden_a="$2" forbidden_b="$3" label="$4" state="$1"
      find "$state" -type d -path '*/git-remote-cache/*/repo.git' \
        | sort > "$state-caches.actual"
      expect_eq "$label cache count" "1" "$(wc -l < "$state-caches.actual")"
      cache="$(cat "$state-caches.actual")"
      case "$cache" in
      "$forbidden_a" | "$forbidden_a"/* | "$forbidden_b" | "$forbidden_b"/*)
        fail "$label cache aliases a source or remote work area"
        ;;
      esac
      expect_eq \
        "$label cache is bare" \
        "true" \
        "$(git --git-dir="$cache" rev-parse --is-bare-repository)"
      git --git-dir="$cache" fsck --connectivity-only > /dev/null \
        || fail "$label cache is not a usable Git repository"
    }

    run_bd() {
      local root="$1" cwd="$2" state="$3"
      shift 3
      (
        cd "$cwd"
        env -i \
          HOME="$root/home" \
          XDG_CACHE_HOME="$root/home/.cache" \
          XDG_CONFIG_HOME="$root/home/.config" \
          XDG_DATA_HOME="$root/home/.local/share" \
          BEADS_DIR="$state" \
          PATH="$PATH" \
          timeout --signal=TERM 120 ${qualifiedBeads}/bin/bd "$@"
      )
    }

    run_old_bd() {
      local root="$1" cwd="$2" state="$3"
      shift 3
      (
        cd "$cwd"
        env -i \
          HOME="$root/home" \
          XDG_CACHE_HOME="$root/home/.cache" \
          XDG_CONFIG_HOME="$root/home/.config" \
          XDG_DATA_HOME="$root/home/.local/share" \
          BEADS_DIR="$state" \
          PATH="$PATH" \
          timeout --signal=TERM 120 ${beads}/bin/bd "$@"
      )
    }

    init_args=(
      init
      --init-if-missing
      --non-interactive
      --prefix contract
      --skip-agents
      --skip-hooks
    )

    probe="$TMPDIR/beads-contracts"
    mkdir -p "$probe/version-home"

    ${vu.goModFloorFn {inherit pkgs;}}

    expect_eq "packaged bd version" "bd version ${qualifiedBeads.version} (dev)" "$(${qualifiedBeads}/bin/bd --version)"
    expect_eq \
      "packaged Dolt version" \
      "dolt version ${dolt.version}" \
      "$(HOME="$probe/version-home" ${dolt}/bin/dolt version | head -n 1)"
    expect_eq \
      "paired Dolt Go floor" \
      "${dolt.goFloor}" \
      "$(go_floor_of "${dolt.src}/go/go.mod")"
    expect_eq "comparison bd version" "bd version 1.0.3 (dev)" "$(${beads}/bin/bd --version)"

    # The contained init primitive: a neutral, non-Git cwd plus an explicit
    # out-of-tree BEADS_DIR. The config has to exist before init so no-git-ops
    # is effective from the first invocation.
    contained="$probe/contained"
    make_home "$contained"
    make_state "$contained/state"
    mkdir -p "$contained/cwd"
    run_bd "$contained" "$contained/cwd" "$contained/state" "''${init_args[@]}" \
      > "$contained/init.out" 2>&1
    [ -z "$(find "$contained/cwd" -mindepth 1 -print -quit)" ] \
      || fail "contained init wrote into its neutral cwd"
    expect_eq "contained state mode" "700" "$(stat -c %a "$contained/state")"
    expect_eq "contained config mode" "600" "$(stat -c %a "$contained/state/config.yaml")"
    expect_eq \
      "contained bd where" \
      "$contained/state" \
      "$(run_bd "$contained" "$contained/cwd" "$contained/state" where --json | jq -r .path)"
    expect_eq \
      "no-git-ops effective value and provenance" \
      "true|config.yaml" \
      "$(run_bd "$contained" "$contained/cwd" "$contained/state" config show --json \
        | jq -r '.[] | select(.key == "no-git-ops") | [.value, .source] | join("|")')"
    expect_eq \
      "embedded auto-commit default" \
      "on" \
      "$(run_bd "$contained" "$contained/cwd" "$contained/state" config show --json \
        | jq -r '.[] | select(.key == "dolt.auto-commit") | .value')"
    run_bd "$contained" "$contained/cwd" "$contained/state" "''${init_args[@]}" \
      > "$contained/second-init.out" 2>&1
    grep -Fq "Skipping init: workspace already initialized." "$contained/second-init.out" \
      || fail "--init-if-missing is not idempotent"

    # With auto-commit disabled, writes remain readable in the Dolt working set
    # without advancing history. One explicit checkpoint commits the batch.
    # cspell:disable-next-line
    contained_db="$(find "$contained/state/embeddeddolt" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    history_before="$(
      cd "$contained_db"
      env -i HOME="$contained/home" PATH="$PATH" ${dolt}/bin/dolt \
        sql -r json -q 'SELECT COUNT(*) AS n FROM dolt_log' | jq -r '.rows[0].n'
    )"
    run_bd "$contained" "$contained/cwd" "$contained/state" \
      --dolt-auto-commit off create "batch one" --silent > /dev/null
    run_bd "$contained" "$contained/cwd" "$contained/state" \
      --dolt-auto-commit off create "batch two" --silent > /dev/null
    history_uncommitted="$(
      cd "$contained_db"
      env -i HOME="$contained/home" PATH="$PATH" ${dolt}/bin/dolt \
        sql -r json -q 'SELECT COUNT(*) AS n FROM dolt_log' | jq -r '.rows[0].n'
    )"
    expect_eq "disabled auto-commit leaves history unchanged" "$history_before" "$history_uncommitted"
    expect_eq \
      "disabled auto-commit keeps rows readable" \
      "2" \
      "$(run_bd "$contained" "$contained/cwd" "$contained/state" list --json | jq length)"
    run_bd "$contained" "$contained/cwd" "$contained/state" \
      dolt commit -m "explicit fixture checkpoint" > /dev/null
    history_after_checkpoint="$(
      cd "$contained_db"
      env -i HOME="$contained/home" PATH="$PATH" ${dolt}/bin/dolt \
        sql -r json -q 'SELECT COUNT(*) AS n FROM dolt_log' | jq -r '.rows[0].n'
    )"
    expect_eq \
      "explicit checkpoint advances history once" \
      "$((history_before + 1))" \
      "$history_after_checkpoint"

    # The tempting source-checkout spellings are not contained. Skip flags
    # suppress agents/hooks but still create and commit Beads files. Stealth
    # avoids that commit but mutates local Git config and info/exclude.
    source_init="$probe/source-init"
    make_home "$source_init"
    mkdir -p "$source_init/repo"
    git -C "$source_init/repo" init -q -b main
    git -C "$source_init/repo" config user.email probe@example.invalid
    git -C "$source_init/repo" config user.name Probe
    git -C "$source_init/repo" commit -q --allow-empty -m seed
    git -C "$source_init/repo" config --local --list | sort > "$source_init/config.before"
    cp "$source_init/repo/.git/info/exclude" "$source_init/exclude.before"
    snapshot_hooks "$source_init/repo/.git/hooks" "$source_init/hooks.before"
    source_before="$(git -C "$source_init/repo" rev-parse HEAD)"
    (
      cd "$source_init/repo"
      env -i HOME="$source_init/home" PATH="$PATH" timeout --signal=TERM 120 \
        ${qualifiedBeads}/bin/bd \
        "''${init_args[@]}" > "$source_init/init.out" 2>&1
    )
    source_after="$(git -C "$source_init/repo" rev-parse HEAD)"
    [ "$source_before" != "$source_after" ] \
      || fail "skip flags unexpectedly stopped bd init from committing"
    expect_eq \
      "ordinary init creates one commit" \
      "1" \
      "$(git -C "$source_init/repo" rev-list --count "$source_before..$source_after")"
    expect_eq \
      "ordinary init commit parent" \
      "$source_before" \
      "$(git -C "$source_init/repo" rev-parse "$source_after^")"
    expect_eq \
      "ordinary init commit subject" \
      "bd init: initialize beads issue tracking" \
      "$(git -C "$source_init/repo" log -1 --format=%s)"
    cat > "$source_init/tracked.expected" <<'FILES'
    .beads/.gitignore
    .beads/README.md
    .beads/config.yaml
    .beads/interactions.jsonl
    .beads/metadata.json
    .gitignore
    FILES
    git -C "$source_init/repo" ls-tree -r --name-only HEAD > "$source_init/tracked.actual"
    diff -u "$source_init/tracked.expected" "$source_init/tracked.actual" \
      || fail "ordinary init tracked residue changed"
    # cspell:ignore embeddeddolt
    cat > "$source_init/state-files.expected" <<'FILES'
    d embeddeddolt
    f .gitignore
    f .local_version
    f README.md
    f config.yaml
    f interactions.jsonl
    f metadata.json
    FILES
    find "$source_init/repo/.beads" -mindepth 1 -maxdepth 1 -printf '%y %f\n' \
      | sort > "$source_init/state-files.actual"
    diff -u "$source_init/state-files.expected" "$source_init/state-files.actual" \
      || fail "ordinary init state residue changed"
    cat > "$source_init/root.expected" <<'FILES'
    d .beads
    d .git
    f .gitignore
    FILES
    find "$source_init/repo" -mindepth 1 -maxdepth 1 -printf '%y %f\n' \
      | sort > "$source_init/root.actual"
    diff -u "$source_init/root.expected" "$source_init/root.actual" \
      || fail "ordinary init root residue changed"
    expect_eq \
      "ordinary init leaves a clean worktree" \
      "" \
      "$(git -C "$source_init/repo" status --short --untracked-files=all)"
    git -C "$source_init/repo" config --local --list | sort > "$source_init/config.after"
    cp "$source_init/config.before" "$source_init/config.expected"
    printf 'beads.role=maintainer\n' >> "$source_init/config.expected"
    sort -o "$source_init/config.expected" "$source_init/config.expected"
    diff -u "$source_init/config.expected" "$source_init/config.after" \
      || fail "ordinary init local Git config changed unexpectedly"
    snapshot_hooks "$source_init/repo/.git/hooks" "$source_init/hooks.after"
    cmp "$source_init/hooks.before" "$source_init/hooks.after" \
      || fail "--skip-hooks changed Git hooks"
    cmp "$source_init/exclude.before" "$source_init/repo/.git/info/exclude" \
      || fail "ordinary init changed info/exclude"
    [ ! -e "$source_init/repo/AGENTS.md" ] || fail "--skip-agents wrote AGENTS.md"
    [ ! -e "$source_init/repo/.git/hooks/pre-commit" ] || fail "--skip-hooks wrote pre-commit"

    stealth="$probe/stealth"
    make_home "$stealth"
    mkdir -p "$stealth/repo"
    git -C "$stealth/repo" init -q -b main
    git -C "$stealth/repo" config user.email probe@example.invalid
    git -C "$stealth/repo" config user.name Probe
    git -C "$stealth/repo" commit -q --allow-empty -m seed
    git -C "$stealth/repo" config --local --list | sort > "$stealth/config.before"
    cp "$stealth/repo/.git/info/exclude" "$stealth/exclude.before"
    snapshot_hooks "$stealth/repo/.git/hooks" "$stealth/hooks.before"
    stealth_before="$(git -C "$stealth/repo" rev-parse HEAD)"
    (
      cd "$stealth/repo"
      env -i HOME="$stealth/home" PATH="$PATH" timeout --signal=TERM 120 \
        ${qualifiedBeads}/bin/bd \
        init --init-if-missing --non-interactive --prefix contract --stealth \
        > "$stealth/init.out" 2>&1
    )
    expect_eq "stealth leaves HEAD" "$stealth_before" "$(git -C "$stealth/repo" rev-parse HEAD)"
    expect_eq "stealth writes beads.role" "maintainer" "$(git -C "$stealth/repo" config beads.role)"
    expect_eq "stealth leaves a clean worktree" "" "$(git -C "$stealth/repo" status --short)"
    expect_eq "stealth config" "no-git-ops: true" "$(cat "$stealth/repo/.beads/config.yaml")"
    git -C "$stealth/repo" config --local --list | sort > "$stealth/config.after"
    cp "$stealth/config.before" "$stealth/config.expected"
    printf 'beads.role=maintainer\n' >> "$stealth/config.expected"
    sort -o "$stealth/config.expected" "$stealth/config.expected"
    diff -u "$stealth/config.expected" "$stealth/config.after" \
      || fail "stealth local Git config changed unexpectedly"
    snapshot_hooks "$stealth/repo/.git/hooks" "$stealth/hooks.after"
    cmp "$stealth/hooks.before" "$stealth/hooks.after" \
      || fail "stealth changed Git hooks"
    [ ! -e "$stealth/repo/AGENTS.md" ] || fail "stealth wrote AGENTS.md"
    find "$stealth/repo/.beads" -mindepth 1 -maxdepth 1 -printf '%y %f\n' \
      | sort > "$stealth/state-files.actual"
    diff -u "$source_init/state-files.expected" "$stealth/state-files.actual" \
      || fail "stealth state residue changed"
    cat > "$stealth/root.expected" <<'FILES'
    d .beads
    d .git
    FILES
    find "$stealth/repo" -mindepth 1 -maxdepth 1 -printf '%y %f\n' \
      | sort > "$stealth/root.actual"
    diff -u "$stealth/root.expected" "$stealth/root.actual" \
      || fail "stealth root residue changed"
    # cspell:ignore proxieddb
    cp "$stealth/exclude.before" "$stealth/exclude.expected"
    cat >> "$stealth/exclude.expected" <<'EXCLUDES'

    # Beads stealth mode (added by bd init --stealth)
    .beads/
    .claude/settings.local.json

    # Beads: Dolt files kept local via .git/info/exclude (stealth / no-git-ops)
    .dolt/
    *.db
    .beads-credential-key
    .beads/proxieddb/
    EXCLUDES
    diff -u "$stealth/exclude.expected" "$stealth/repo/.git/info/exclude" \
      || fail "stealth exclude mutation changed"

    # Unset discovery follows the common Git directory into linked worktrees.
    # A missing or empty BEADS_DIR does not fail closed: it is ignored and the
    # source workspace wins, so consumers must assert `bd where` exactly.
    git -C "$source_init/repo" worktree add -q -b linked "$source_init/linked"
    main_where="$(
      cd "$source_init/repo"
      env -i HOME="$source_init/home" PATH="$PATH" ${qualifiedBeads}/bin/bd where --json | jq -r .path
    )"
    expect_eq "source checkout discovery" "$source_init/repo/.beads" "$main_where"
    linked_where="$(
      cd "$source_init/linked"
      env -i HOME="$source_init/home" PATH="$PATH" ${qualifiedBeads}/bin/bd where --json | jq -r .path
    )"
    expect_eq "linked-worktree discovery" "$main_where" "$linked_where"
    mkdir -p "$source_init/empty-state"
    fallback_where="$(run_bd "$source_init" "$source_init/repo" "$source_init/empty-state" \
      where --json | jq -r .path)"
    expect_eq "empty BEADS_DIR falls back" "$main_where" "$fallback_where"
    fallback_where="$(run_bd "$source_init" "$source_init/repo" "$source_init/absent-state" \
      where --json | jq -r .path)"
    expect_eq "missing BEADS_DIR falls back" "$main_where" "$fallback_where"
    [ ! -e "$source_init/absent-state" ] \
      || fail "missing BEADS_DIR fallback materialized the absent path"

    # Independent writers launched from a checkout and its linked worktree can
    # share one external embedded workspace. The fallback is safe but slow;
    # external server mode remains the intended concurrent topology.
    writer_labels=()
    writer_processes=()
    for writer in 1 2 3 4; do
      run_bd "$contained" "$source_init/repo" "$contained/state" \
        create "main writer $writer" --silent > "$contained/main-$writer.out" &
      writer_processes+=("$!")
      writer_labels+=("main-$writer")
      run_bd "$contained" "$source_init/linked" "$contained/state" \
        create "linked writer $writer" --silent > "$contained/linked-$writer.out" &
      writer_processes+=("$!")
      writer_labels+=("linked-$writer")
    done
    for index in "''${!writer_processes[@]}"; do
      if ! wait "''${writer_processes[$index]}"; then
        fail "linked-worktree writer ''${writer_labels[$index]} failed"
      fi
    done
    expect_eq \
      "linked-worktree embedded writers persist" \
      "10" \
      "$(run_bd "$contained" "$contained/cwd" "$contained/state" list --json | jq length)"
    for writer in 1 2 3 4; do
      run_bd "$contained" "$contained/cwd" "$contained/state" list --json \
        | jq -e --arg title "main writer $writer" 'any(.[]; .title == $title)' > /dev/null \
        || fail "main writer $writer row is missing"
      run_bd "$contained" "$contained/cwd" "$contained/state" list --json \
        | jq -e --arg title "linked writer $writer" 'any(.[]; .title == $title)' > /dev/null \
        || fail "linked writer $writer row is missing"
    done

    missing="$probe/missing"
    make_home "$missing"
    mkdir -p "$missing/cwd"
    if run_bd "$missing" "$missing/cwd" "$missing/absent" where --json \
      > "$missing/where.out" 2>&1; then
      fail "missing workspace outside Git unexpectedly succeeded"
    fi
    jq -e '.error == "no_beads_directory"' "$missing/where.out" > /dev/null \
      || fail "missing workspace error shape changed"

    # Without --remote, bd inherits the source origin as its Dolt remote. The
    # declarative boundary must therefore always pass and verify the ledger URL.
    # Dolt keeps a dedicated bare cache even when that URL could also be the
    # source origin.
    remote="$probe/remote"
    make_home "$remote"
    mkdir -p "$remote/source" "$remote/ledger.git" "$remote/source.git"
    git -C "$remote/ledger.git" init -q --bare
    git -C "$remote/source.git" init -q --bare
    git -C "$remote/source" init -q -b main
    git -C "$remote/source" config user.email probe@example.invalid
    git -C "$remote/source" config user.name Probe
    git -C "$remote/source" commit -q --allow-empty -m seed
    git -C "$remote/source" remote add origin "file://$remote/source.git"
    git -C "$remote/source" push -q origin main

    make_state "$remote/no-remote-state"
    run_bd "$remote" "$remote/source" "$remote/no-remote-state" "''${init_args[@]}" \
      > "$remote/no-remote-init.out" 2>&1
    expect_eq \
      "source origin is inherited without an override" \
      "git+file://$remote/source.git" \
      "$(run_bd "$remote" "$remote/source" "$remote/no-remote-state" \
        dolt remote list --json | jq -r '.[0].url')"
    inherited_issue="$(run_bd "$remote" "$remote/source" "$remote/no-remote-state" \
      create "preserved across remote repair" --silent)"
    run_bd "$remote" "$remote/source" "$remote/no-remote-state" "''${init_args[@]}" \
      --remote "file://$remote/ledger.git" > "$remote/second-init-with-remote.out" 2>&1
    grep -Fq "Skipping init: workspace already initialized." "$remote/second-init-with-remote.out" \
      || fail "existing-state init did not skip"
    expect_eq \
      "existing-state init leaves inherited remote unchanged" \
      "git+file://$remote/source.git" \
      "$(run_bd "$remote" "$remote/source" "$remote/no-remote-state" \
        dolt remote list --json | jq -r '.[0].url')"
    run_bd "$remote" "$remote/source" "$remote/no-remote-state" \
      dolt remote add origin "file://$remote/ledger.git" > "$remote/repair-remote.out"
    expect_eq \
      "remote add repairs config pass-through" \
      "file://$remote/ledger.git" \
      "$(run_bd "$remote" "$remote/source" "$remote/no-remote-state" config show --json \
        | jq -r '.[] | select(.key == "sync.remote") | .value')"
    expect_eq \
      "remote add repairs the complete remote set" \
      "[{\"name\":\"origin\",\"url\":\"git+file://$remote/ledger.git\",\"sql_url\":\"git+file://$remote/ledger.git\",\"status\":\"ok\"}]" \
      "$(run_bd "$remote" "$remote/source" "$remote/no-remote-state" \
        dolt remote list --json | jq -c '[.[] | {name, url, sql_url, status}]')"
    run_bd "$remote" "$remote/source" "$remote/no-remote-state" \
      show "$inherited_issue" --json > /dev/null

    make_state "$remote/equal-url-state"
    run_bd "$remote" "$remote/source" "$remote/equal-url-state" "''${init_args[@]}" \
      --remote "file://$remote/source.git" > "$remote/equal-url-init.out" 2>&1
    expect_eq \
      "equal source and ledger URL is explicit" \
      "file://$remote/source.git" \
      "$(run_bd "$remote" "$remote/source" "$remote/equal-url-state" config show --json \
        | jq -r '.[] | select(.key == "sync.remote") | .value')"
    expect_eq \
      "equal URL complete remote set" \
      "[{\"name\":\"origin\",\"url\":\"git+file://$remote/source.git\",\"sql_url\":\"git+file://$remote/source.git\",\"status\":\"ok\"}]" \
      "$(run_bd "$remote" "$remote/source" "$remote/equal-url-state" \
        dolt remote list --json | jq -c '[.[] | {name, url, sql_url, status}]')"
    source_remote_main="$(git -C "$remote/source.git" rev-parse refs/heads/main)"
    run_bd "$remote" "$remote/source" "$remote/equal-url-state" \
      create "equal URL seed" --silent > /dev/null
    run_bd "$remote" "$remote/source" "$remote/equal-url-state" dolt push \
      > "$remote/equal-url-push.out"
    assert_bare_cache \
      "$remote/equal-url-state" \
      "$remote/source" \
      "$remote/source.git" \
      "equal URL"
    expect_eq \
      "equal URL publication leaves source main unchanged" \
      "$source_remote_main" \
      "$(git -C "$remote/source.git" rev-parse refs/heads/main)"

    # The Git remote adapter refuses a completely unborn remote loudly and does
    # not leave a partial Dolt ref. Seed an ordinary branch only after that proof.
    make_state "$remote/unborn-state"
    if run_bd "$remote" "$remote/source" "$remote/unborn-state" "''${init_args[@]}" \
      --remote "file://$remote/ledger.git" > "$remote/unborn-init.out" 2>&1; then
      fail "init from an unborn Git remote unexpectedly succeeded"
    fi
    grep -Fq "git remote has no branches" "$remote/unborn-init.out" \
      || fail "unborn Git remote failure shape changed"
    if git -C "$remote/ledger.git" rev-parse --verify refs/dolt/data > /dev/null 2>&1; then
      fail "failed unborn push left refs/dolt/data"
    fi
    git -C "$remote/source" push -q "file://$remote/ledger.git" main:main
    make_state "$remote/state-a"
    run_bd "$remote" "$remote/source" "$remote/state-a" "''${init_args[@]}" \
      --remote "file://$remote/ledger.git" > "$remote/init-a.out" 2>&1
    expect_eq \
      "ledger URL config pass-through" \
      "file://$remote/ledger.git" \
      "$(run_bd "$remote" "$remote/source" "$remote/state-a" config show --json \
        | jq -r '.[] | select(.key == "sync.remote") | .value')"
    expect_eq \
      "declared ledger is the complete remote set" \
      "[{\"name\":\"origin\",\"url\":\"git+file://$remote/ledger.git\",\"sql_url\":\"git+file://$remote/ledger.git\",\"status\":\"ok\"}]" \
      "$(run_bd "$remote" "$remote/source" "$remote/state-a" \
        dolt remote list --json | jq -c '[.[] | {name, url, sql_url, status}]')"
    expect_eq \
      "source origin stays distinct" \
      "file://$remote/source.git" \
      "$(git -C "$remote/source" remote get-url origin)"

    first_id="$(run_bd "$remote" "$remote/source" "$remote/state-a" \
      create "remote seed" --silent)"
    run_bd "$remote" "$remote/source" "$remote/state-a" dolt push \
      > "$remote/first-push.out"
    git -C "$remote/ledger.git" rev-parse --verify refs/dolt/data > /dev/null \
      || fail "explicit push did not create refs/dolt/data"
    git -C "$remote/ledger.git" rev-parse --verify refs/heads/__dolt_remote_info__ > /dev/null \
      || fail "explicit push did not create the Dolt remote metadata ref"
    assert_bare_cache \
      "$remote/state-a" \
      "$remote/source" \
      "$remote/ledger.git" \
      "declared ledger"

    published="$(git -C "$remote/ledger.git" rev-parse refs/dolt/data)"
    local_id="$(run_bd "$remote" "$remote/source" "$remote/state-a" \
      create "local only" --silent)"
    expect_eq \
      "writes do not publish in background" \
      "$published" \
      "$(git -C "$remote/ledger.git" rev-parse refs/dolt/data)"

    make_home "$remote/clone-b"
    make_state "$remote/clone-b/state"
    mkdir -p "$remote/clone-b/cwd"
    run_bd "$remote/clone-b" "$remote/clone-b/cwd" "$remote/clone-b/state" \
      "''${init_args[@]}" --remote "file://$remote/ledger.git" \
      > "$remote/init-b.out" 2>&1
    run_bd "$remote/clone-b" "$remote/clone-b/cwd" "$remote/clone-b/state" \
      show "$first_id" --json > /dev/null
    if run_bd "$remote/clone-b" "$remote/clone-b/cwd" "$remote/clone-b/state" \
      show "$local_id" --json > "$remote/clone-b-local-only.out" 2>&1; then
      fail "unpublished issue appeared in an independently bootstrapped clone"
    fi
    expect_eq \
      "independent bootstrap excludes unpublished rows" \
      "1" \
      "$(run_bd "$remote/clone-b" "$remote/clone-b/cwd" "$remote/clone-b/state" \
        list --json | jq length)"
    expect_eq \
      "independent bootstrap observes no delayed publication" \
      "$published" \
      "$(git -C "$remote/ledger.git" rev-parse refs/dolt/data)"

    run_bd "$remote" "$remote/source" "$remote/state-a" dolt push \
      > "$remote/push-a.out"
    run_bd "$remote/clone-b" "$remote/clone-b/cwd" "$remote/clone-b/state" \
      create "divergent clone" --silent > /dev/null
    if run_bd "$remote/clone-b" "$remote/clone-b/cwd" "$remote/clone-b/state" \
      dolt push > "$remote/stale-push.out" 2>&1; then
      fail "stale clone push unexpectedly succeeded"
    fi
    grep -Fq "non-fast-forward" "$remote/stale-push.out" \
      || fail "stale clone did not fail loudly"

    # Dolt's supported state root contains both global config and local event
    # files. No-flush alone still collects; metrics.disabled=true prevents the
    # event payloads while retaining a lock file.
    telemetry="$probe/telemetry"
    mkdir -p "$telemetry/control-home" "$telemetry/control-repo"
    (
      cd "$telemetry/control-repo"
      env -i HOME="$telemetry/control-home" DOLT_DISABLE_EVENT_FLUSH=1 PATH="$PATH" \
        ${dolt}/bin/dolt config --global --add user.email probe@example.invalid
      env -i HOME="$telemetry/control-home" DOLT_DISABLE_EVENT_FLUSH=1 PATH="$PATH" \
        ${dolt}/bin/dolt config --global --add user.name Probe
      env -i HOME="$telemetry/control-home" DOLT_DISABLE_EVENT_FLUSH=1 PATH="$PATH" \
        ${dolt}/bin/dolt init
      env -i HOME="$telemetry/control-home" DOLT_DISABLE_EVENT_FLUSH=1 PATH="$PATH" \
        ${dolt}/bin/dolt status > /dev/null
    )
    # cspell:disable-next-line
    find "$telemetry/control-home/.dolt/eventsData" -name '*.devts' -print -quit \
      | grep -q . || fail "no-flush control no longer creates local Dolt events"
    expect_eq \
      "Dolt global config mode" \
      "777" \
      "$(stat -c %a "$telemetry/control-home/.dolt/config_global.json")"

    mkdir -p \
      "$telemetry/contained-home" \
      "$telemetry/contained-root" \
      "$telemetry/contained-repo"
    chmod 700 "$telemetry/contained-home" "$telemetry/contained-root"
    env -i HOME="$telemetry/contained-home" DOLT_ROOT_PATH="$telemetry/contained-root" \
      DOLT_DISABLE_EVENT_FLUSH=1 PATH="$PATH" \
      ${dolt}/bin/dolt config --global --add metrics.disabled true
    env -i HOME="$telemetry/contained-home" DOLT_ROOT_PATH="$telemetry/contained-root" \
      DOLT_DISABLE_EVENT_FLUSH=1 PATH="$PATH" \
      ${dolt}/bin/dolt config --global --add user.email probe@example.invalid
    env -i HOME="$telemetry/contained-home" DOLT_ROOT_PATH="$telemetry/contained-root" \
      DOLT_DISABLE_EVENT_FLUSH=1 PATH="$PATH" \
      ${dolt}/bin/dolt config --global --add user.name Probe
    (
      cd "$telemetry/contained-repo"
      env -i HOME="$telemetry/contained-home" DOLT_ROOT_PATH="$telemetry/contained-root" \
        DOLT_DISABLE_EVENT_FLUSH=1 PATH="$PATH" ${dolt}/bin/dolt init
      env -i HOME="$telemetry/contained-home" DOLT_ROOT_PATH="$telemetry/contained-root" \
        DOLT_DISABLE_EVENT_FLUSH=1 PATH="$PATH" ${dolt}/bin/dolt status > /dev/null
    )
    [ -z "$(find "$telemetry/contained-home" -mindepth 1 -print -quit)" ] \
      || fail "DOLT_ROOT_PATH leaked Dolt state into HOME"
    [ -f "$telemetry/contained-root/.dolt/config_global.json" ] \
      || fail "DOLT_ROOT_PATH did not contain global config"
    expect_eq \
      "contained Dolt outer-root mode" \
      "700" \
      "$(stat -c %a "$telemetry/contained-root")"
    expect_eq \
      "Dolt preserves its broad inner config mode" \
      "777" \
      "$(stat -c %a "$telemetry/contained-root/.dolt/config_global.json")"
    expect_eq \
      "contained metrics disable value" \
      "true" \
      "$(env -i HOME="$telemetry/contained-home" \
        DOLT_ROOT_PATH="$telemetry/contained-root" PATH="$PATH" \
        ${dolt}/bin/dolt config --global --get metrics.disabled)"
    cat > "$telemetry/contained-events.expected" <<'EVENTS'
    d 755 .dolt
    d 755 .dolt/eventsData
    f 777 .dolt/config_global.json
    f 777 .dolt/eventsData/dolt.lock
    EVENTS
    find "$telemetry/contained-root" -mindepth 1 \
      -printf '%y %m %P\n' | sort > "$telemetry/contained-events.actual"
    diff -u "$telemetry/contained-events.expected" "$telemetry/contained-events.actual" \
      || fail "contained Dolt telemetry residue changed"
    # cspell:disable-next-line
    if find "$telemetry/contained-root/.dolt/eventsData" -name '*.devts' -print -quit \
      | grep -q .; then
      fail "metrics.disabled=true still created Dolt event payloads"
    fi

    # The available older client rejects a dedicated freshly initialized 1.2.2
    # database before any issue write.
    fresh_new="$probe/fresh-new"
    make_home "$fresh_new"
    make_state "$fresh_new/state"
    mkdir -p "$fresh_new/cwd"
    run_bd "$fresh_new" "$fresh_new/cwd" "$fresh_new/state" "''${init_args[@]}" \
      > "$fresh_new/init.out" 2>&1
    if run_old_bd "$fresh_new" "$fresh_new/cwd" "$fresh_new/state" list --json \
      > "$fresh_new/old-client.out" 2>&1; then
      fail "bd 1.0.3 unexpectedly opened a fresh 1.2.2 database"
    fi
    grep -Fq "table has unknown fields" "$fresh_new/old-client.out" \
      || fail "older-client refusal shape changed"

    # The reverse direction opens and remains writable, while migration
    # inspection only reports a version-label mismatch; this release pair does
    # not exercise a destructive migration.
    upgrade="$probe/upgrade"
    make_home "$upgrade"
    make_state "$upgrade/state"
    mkdir -p "$upgrade/cwd"
    run_old_bd "$upgrade" "$upgrade/cwd" "$upgrade/state" \
      init --non-interactive --prefix upgrade --skip-agents --skip-hooks \
      > "$upgrade/init.out" 2>&1
    run_old_bd "$upgrade" "$upgrade/cwd" "$upgrade/state" \
      create "old issue" --silent > /dev/null
    run_bd "$upgrade" "$upgrade/cwd" "$upgrade/state" list --json > /dev/null
    run_bd "$upgrade" "$upgrade/cwd" "$upgrade/state" \
      create "new issue" --silent > /dev/null
    expect_eq \
      "new client remains writable on older database" \
      "2" \
      "$(run_old_bd "$upgrade" "$upgrade/cwd" "$upgrade/state" list --json | jq length)"
    run_bd "$upgrade" "$upgrade/cwd" "$upgrade/state" migrate --inspect --json \
      > "$upgrade/inspect.out" 2>&1
    grep -Fq "schema version mismatch (current: 1.0.3, expected: 1.2.2)" \
      "$upgrade/inspect.out" || fail "upgrade inspection mismatch warning changed"
    run_bd "$upgrade" "$upgrade/cwd" "$upgrade/state" migrate schema --json \
      > "$upgrade/schema.out" 2>&1
    grep -Fq "Schema already at v53" "$upgrade/schema.out" \
      || fail "explicit schema migration result changed"

    touch "$out"
  ''
