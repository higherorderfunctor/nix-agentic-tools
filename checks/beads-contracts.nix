# Black-box contracts for the exact Beads and Dolt packages used by the MVP.
#
# These assertions deliberately include surprising upstream behavior that the
# module must defend against. If a future package fixes one, this check should
# fail so the lifecycle and reference can be simplified from fresh evidence.
{pkgs, ...}: let
  inherit (pkgs) beads dolt;
  qualifiedBeads = pkgs.ai.devTools.beads;
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
          ${qualifiedBeads}/bin/bd "$@"
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
          ${beads}/bin/bd "$@"
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

    expect_eq "packaged bd version" "bd version 1.2.2 (dev)" "$(${qualifiedBeads}/bin/bd --version)"
    expect_eq \
      "packaged Dolt version" \
      "dolt version 2.2.3" \
      "$(HOME="$probe/version-home" ${dolt}/bin/dolt version | head -n 1)"
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
    expect_eq \
      "contained bd where" \
      "$contained/state" \
      "$(run_bd "$contained" "$contained/cwd" "$contained/state" where --json | jq -r .path)"
    expect_eq \
      "no-git-ops provenance" \
      "config.yaml" \
      "$(run_bd "$contained" "$contained/cwd" "$contained/state" config show --json \
        | jq -r '.[] | select(.key == "no-git-ops") | .source')"
    expect_eq \
      "embedded auto-commit default" \
      "on" \
      "$(run_bd "$contained" "$contained/cwd" "$contained/state" config show --json \
        | jq -r '.[] | select(.key == "dolt.auto-commit") | .value')"
    run_bd "$contained" "$contained/cwd" "$contained/state" "''${init_args[@]}" \
      > "$contained/second-init.out" 2>&1
    grep -Fq "Skipping init: workspace already initialized." "$contained/second-init.out" \
      || fail "--init-if-missing is not idempotent"

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
    source_before="$(git -C "$source_init/repo" rev-parse HEAD)"
    (
      cd "$source_init/repo"
      env -i HOME="$source_init/home" PATH="$PATH" ${qualifiedBeads}/bin/bd \
        "''${init_args[@]}" > "$source_init/init.out" 2>&1
    )
    source_after="$(git -C "$source_init/repo" rev-parse HEAD)"
    [ "$source_before" != "$source_after" ] \
      || fail "skip flags unexpectedly stopped bd init from committing"
    [ ! -e "$source_init/repo/AGENTS.md" ] || fail "--skip-agents wrote AGENTS.md"
    [ ! -e "$source_init/repo/.git/hooks/pre-commit" ] || fail "--skip-hooks wrote pre-commit"

    stealth="$probe/stealth"
    make_home "$stealth"
    mkdir -p "$stealth/repo"
    git -C "$stealth/repo" init -q -b main
    git -C "$stealth/repo" config user.email probe@example.invalid
    git -C "$stealth/repo" config user.name Probe
    git -C "$stealth/repo" commit -q --allow-empty -m seed
    stealth_before="$(git -C "$stealth/repo" rev-parse HEAD)"
    (
      cd "$stealth/repo"
      env -i HOME="$stealth/home" PATH="$PATH" ${qualifiedBeads}/bin/bd \
        "''${init_args[@]}" --stealth > "$stealth/init.out" 2>&1
    )
    expect_eq "stealth leaves HEAD" "$stealth_before" "$(git -C "$stealth/repo" rev-parse HEAD)"
    expect_eq "stealth writes beads.role" "maintainer" "$(git -C "$stealth/repo" config beads.role)"
    grep -Fq ".beads/" "$stealth/repo/.git/info/exclude" \
      || fail "stealth did not mutate .git/info/exclude"

    # Unset discovery follows the common Git directory into linked worktrees.
    # A missing or empty BEADS_DIR does not fail closed: it is ignored and the
    # source workspace wins, so consumers must assert `bd where` exactly.
    git -C "$source_init/repo" worktree add -q -b linked "$source_init/linked"
    main_where="$(
      cd "$source_init/repo"
      env -i HOME="$source_init/home" PATH="$PATH" ${qualifiedBeads}/bin/bd where --json | jq -r .path
    )"
    linked_where="$(
      cd "$source_init/linked"
      env -i HOME="$source_init/home" PATH="$PATH" ${qualifiedBeads}/bin/bd where --json | jq -r .path
    )"
    expect_eq "linked-worktree discovery" "$main_where" "$linked_where"
    mkdir -p "$source_init/empty-state"
    fallback_where="$(run_bd "$source_init" "$source_init/repo" "$source_init/empty-state" \
      where --json | jq -r .path)"
    expect_eq "empty BEADS_DIR falls back" "$main_where" "$fallback_where"

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

    # The Git remote adapter refuses a completely unborn remote. Seed an ordinary
    # branch first; Dolt publication remains isolated on refs/dolt/data.
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
      "Dolt URL normalization" \
      "git+file://$remote/ledger.git" \
      "$(run_bd "$remote" "$remote/source" "$remote/state-a" \
        dolt remote list --json | jq -r '.[0].url')"
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
    find "$remote/state-a" -type d -path '*/git-remote-cache/*/repo.git' -print -quit \
      | grep -q . || fail "Dolt did not create a dedicated local bare cache"

    published="$(git -C "$remote/ledger.git" rev-parse refs/dolt/data)"
    run_bd "$remote" "$remote/source" "$remote/state-a" \
      create "local only" --silent > /dev/null
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
    run_bd "$remote/clone-b" "$remote/clone-b/cwd" "$remote/clone-b/state" dolt pull \
      > "$remote/pull-b.out"
    run_bd "$remote/clone-b" "$remote/clone-b/cwd" "$remote/clone-b/state" dolt push \
      > "$remote/push-b.out"
    run_bd "$remote" "$remote/source" "$remote/state-a" dolt pull \
      > "$remote/pull-a.out"
    expect_eq \
      "divergent history preserves all issues" \
      "3" \
      "$(run_bd "$remote" "$remote/source" "$remote/state-a" list --json | jq length)"

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

    mkdir -p "$telemetry/contained-root" "$telemetry/contained-repo"
    env -i HOME="$telemetry/control-home" DOLT_ROOT_PATH="$telemetry/contained-root" \
      DOLT_DISABLE_EVENT_FLUSH=1 PATH="$PATH" \
      ${dolt}/bin/dolt config --global --add metrics.disabled true
    env -i HOME="$telemetry/control-home" DOLT_ROOT_PATH="$telemetry/contained-root" \
      DOLT_DISABLE_EVENT_FLUSH=1 PATH="$PATH" \
      ${dolt}/bin/dolt config --global --add user.email probe@example.invalid
    env -i HOME="$telemetry/control-home" DOLT_ROOT_PATH="$telemetry/contained-root" \
      DOLT_DISABLE_EVENT_FLUSH=1 PATH="$PATH" \
      ${dolt}/bin/dolt config --global --add user.name Probe
    (
      cd "$telemetry/contained-repo"
      env -i HOME="$telemetry/control-home" DOLT_ROOT_PATH="$telemetry/contained-root" \
        DOLT_DISABLE_EVENT_FLUSH=1 PATH="$PATH" ${dolt}/bin/dolt init
      env -i HOME="$telemetry/control-home" DOLT_ROOT_PATH="$telemetry/contained-root" \
        DOLT_DISABLE_EVENT_FLUSH=1 PATH="$PATH" ${dolt}/bin/dolt status > /dev/null
    )
    [ -f "$telemetry/contained-root/.dolt/config_global.json" ] \
      || fail "DOLT_ROOT_PATH did not contain global config"
    # cspell:disable-next-line
    if find "$telemetry/contained-root/.dolt/eventsData" -name '*.devts' -print -quit \
      | grep -q .; then
      fail "metrics.disabled=true still created Dolt event payloads"
    fi

    # The available older client rejects a freshly initialized 1.2.2 database
    # because newer table fields are unknown. The reverse direction opens and
    # remains writable, while migration inspection only reports a version-label
    # mismatch; this release pair does not exercise a destructive migration.
    if run_old_bd "$contained" "$contained/cwd" "$contained/state" list --json \
      > "$contained/old-client.out" 2>&1; then
      fail "bd 1.0.3 unexpectedly opened a fresh 1.2.2 database"
    fi
    grep -Fq "table has unknown fields" "$contained/old-client.out" \
      || fail "older-client refusal shape changed"

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

    touch "$out"
  ''
