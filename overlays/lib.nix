# overlays/lib.nix — DRY version extraction + smoke test helpers.
#
# Each helper reads a manifest from a Nix store path (src) at eval
# time and returns the upstream version string. Callers combine it
# with `builtins.substring 0 7 rev` to produce "x.y.z+abc1234".
#
# `rec` so a composed helper can call a sibling —
# `ghArchiveUpdateScript` is `mkUpdateScript` + `ghLatestVersionCmd`
# with one argument threaded through both, and duplicating either
# body to avoid the self-reference would be the DRY loss this file
# exists to prevent. Same shape as lib/ai/transformers/*.nix.
rec {
  # Format: "{upstream}+{shortrev}"
  mkVersion = {
    upstream,
    rev,
  }: "${upstream}+${builtins.substring 0 7 rev}";

  # Read version from Cargo.toml [package] section.
  readCargoVersion = path:
    (builtins.fromTOML (builtins.readFile path)).package.version;

  # Read version from [workspace.package] in a workspace root Cargo.toml.
  readCargoWorkspaceVersion = path:
    (builtins.fromTOML (builtins.readFile path)).workspace.package.version;

  # Read version from pyproject.toml [project] section.
  readPyprojectVersion = path:
    (builtins.fromTOML (builtins.readFile path)).project.version;

  # Read version from package.json.
  readPackageJsonVersion = path:
    (builtins.fromJSON (builtins.readFile path)).version;

  # Read __version__ = "..." from a Python file.
  readPythonDunderVersion = path: let
    content = builtins.readFile path;
    lines = builtins.filter (l: builtins.isString l && l != "") (builtins.split "\n" content);
    vLine = builtins.head (builtins.filter (l: builtins.match "^__version__ = \".*\"$" l != null) lines);
  in
    builtins.head (builtins.match "^__version__ = \"(.*)\"$" vLine);

  # Generate an installCheckPhase for MCP stdio servers.
  # Feeds /dev/null to stdin, captures stderr+stdout, verifies the process
  # started (non-empty output or specific marker). Kills after 2s timeout.
  mkMcpSmokeTest = {
    bin,
    args ? [],
    marker ? null,
  }: let
    argStr = builtins.concatStringsSep " " args;
    check =
      if marker != null
      then ''
        # Here-string, not `echo "$output" | grep -Fq`. stdenv arms
        # `set -o pipefail` for every build phase (setup line 12), and bash's
        # echo builtin writes a captured multi-line string a line at a time —
        # so `grep -Fq` exiting at its first match leaves the remaining writes
        # to EPIPE, poisoning the pipeline status and flipping this `if` to the
        # "marker not found" branch on output that DOES contain the marker.
        if grep -Fq "${marker}" <<<"$output"; then
          echo "smoke-test: found marker '${marker}'"
        else
          echo "smoke-test: marker '${marker}' not found in output:" >&2
          echo "$output" >&2
          exit 1
        fi
      ''
      else ''
        echo "smoke-test: process started (exit ok)"
      '';
  in ''
    runHook preInstallCheck
    echo "Running MCP smoke test for ${bin}..."
    output=$(timeout 2 $out/bin/${bin} ${argStr} < /dev/null 2>&1 || true)
    ${check}
    runHook postInstallCheck
  '';

  # Generate an updateScript for main-tracking packages that use a bare
  # `rev = "..."` in their overlay .nix file. Fetches the latest commit
  # SHA from the default branch via git ls-remote, then sed-replaces the
  # rev line. nix-update --version skip handles hash updates afterward.
  #
  # url: git remote URL (e.g., "https://github.com/owner/repo.git")
  # file: overlay .nix file path relative to repo root
  # rev: current rev string (used as the old value to replace)
  # pkgs: nixpkgs set (for git)
  mkGitRevUpdateScript = {
    url,
    file,
    rev,
    pkgs,
  }:
    pkgs.writeShellScript "update-rev" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      new_rev=$(${pkgs.git}/bin/git ls-remote "${url}" HEAD | ${pkgs.coreutils}/bin/cut -f1)
      # Still reachable under pipefail, and still required. pipefail now
      # catches the case this used to catch — ls-remote FAILING while cut
      # succeeds on empty input — one step earlier, at the assignment.
      # What it cannot catch is ls-remote SUCCEEDING and printing nothing
      # (an empty remote, or HEAD matching no ref): status 0, empty
      # capture, no errexit. That case lands here.
      if [ -z "$new_rev" ]; then
        echo "Failed to fetch latest rev from ${url}" >&2
        exit 1
      fi
      if [ "$new_rev" = "${rev}" ]; then
        echo "Already at latest rev"
        exit 0
      fi
      ${pkgs.gnused}/bin/sed -i "s|${rev}|$new_rev|" "${file}"
      echo "Updated rev: ${rev} -> $new_rev"
    '';

  # Grep claude's binary for its launch-effort pin keys, the effort enum,
  # the workflow/ultracode boolean settings keys we depend on, the hook-event
  # vocabulary, and the model catalog, emitting `{launchEffortPins,
  # effortLevels, settingsBooleanKeys, hookEvents, models}` to `dest`
  # (default stdout). Single source of the grep logic — used by
  # claude-code.nix's passthru.extracted (and, transitively, by
  # mkUpdateScript). Fails loud (exit 1) if any anchor comes up empty (or,
  # for the effort enum, != exactly one match) — so an upstream change
  # breaks the build instead of silently extracting nothing.
  #
  # EVERY key here becomes an option surface in mkClaude.nix, so a dead
  # anchor does not merely lose data: it puts the HM/devenv module options
  # out of sync with the binary they are supposed to describe. That is the
  # whole reason the guards below are hard failures rather than warnings,
  # and why the emitted sidecar is committed and drift-checked.
  #
  # The `settingsBooleanKeys` guard covers `ultracode` (UNDOCUMENTED,
  # officially session-only — persisted via ai.claude.ultracodeOnLaunch),
  # `enableWorkflows`, and `workflowKeywordTriggerEnabled`. These are
  # off-label / /config-only keys with no compatibility promise; asserting
  # they still parse as boolean-schema settings keys on each claude-code
  # bump converts a future silent drop into a loud update-pipeline (and
  # `nix flake check` drift-check) failure. See mkClaude.nix for the option
  # surface and docs/plans/ultracode-typed-options-and-meta-option.md § 3.
  #   bin:  absolute path to the claude binary.
  #   pkgs: nixpkgs set (gnugrep, gnused, coreutils, jq).
  #   dest: output path (default "/dev/stdout"; pass "$out" in runCommand).
  mkClaudeExtract = {
    bin,
    pkgs,
    dest ? "/dev/stdout",
  }: ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    comm="${pkgs.coreutils}/bin/comm"
    grep="${pkgs.gnugrep}/bin/grep"
    jq="${pkgs.jq}/bin/jq"
    sed="${pkgs.gnused}/bin/sed"
    sort="${pkgs.coreutils}/bin/sort"

    pins=$("$grep" -aoE 'unpin[A-Za-z0-9]+LaunchEffort' "${bin}" | "$sort" -u || true)
    if [ -z "$pins" ]; then
      echo "claude-extract: no unpin*LaunchEffort keys found (upstream renamed the launch-pin mechanism)" >&2
      exit 1
    fi

    # The persisted-settings effort validator. The minifier variable
    # before `.enum` is rebuilt every release (2.1.159 emitted `y`,
    # 2.1.181 emitted `H`), so match ANY identifier and key on the
    # `effortLevel:` prefix + the enum literal instead of a fixed token.
    # Extract the level array; require exactly one DISTINCT match so an
    # upstream shape change still fails loud.
    levels=$("$grep" -aoE 'effortLevel:[A-Za-z_$][A-Za-z0-9_$]*\.enum\(\[[^]]*\]\)' "${bin}" \
      | "$grep" -oE '\[[^]]*\]' | "$sort" -u)
    matchCount=$(printf '%s\n' "$levels" | "$grep" -c . || true)
    if [ "$matchCount" -ne 1 ]; then
      echo "claude-extract: effort enum matched $matchCount distinct level arrays (expected 1; upstream changed the validator)" >&2
      exit 1
    fi

    # Guard the workflow/ultracode boolean settings keys. Each is registered
    # in the settings schema as `<key>:<ident>.boolean()`. The minifier
    # identifier is rebuilt every release (2.1.202 emitted `A`), so match ANY
    # identifier and key on the `<key>:` prefix + `.boolean()` literal. Unlike
    # the effort enum above — which strips to the `[...]` array payload so
    # repeated occurrences collapse — a boolean key has no payload to validate
    # AND can appear MORE THAN ONCE (2.1.202 emits `ultracode:<ident>.boolean()`
    # twice, sharing an identifier only by coincidence). So we must NOT dedup on
    # the ident-bearing string: check PRESENCE (>= 1 raw match), not
    # exactly-one-distinct — otherwise a future re-minification that splits the
    # two idents apart would fail this guard spuriously (keyCount 2 != 1). The
    # trailing `|| true` keeps the zero-match case from aborting at the
    # assignment (pipefail + inherit_errexit) so the not-found branch is
    # reachable and fails loud with its own message.
    boolKeys=(ultracode enableWorkflows workflowKeywordTriggerEnabled)
    for key in "''${boolKeys[@]}"; do
      keyHits=$("$grep" -aoE "$key"':[A-Za-z_$][A-Za-z0-9_$]*\.boolean\(\)' "${bin}" | "$grep" -c . || true)
      if [ "$keyHits" -lt 1 ]; then
        echo "claude-extract: settings key '$key' not found as a boolean-schema registration (upstream renamed/removed it or changed the schema)" >&2
        exit 1
      fi
    done

    # Hook events — the northbound soft-enum `knownEvents`. Grep every flat array
    # literal containing the "PreToolUse" token (the canonical first hook event),
    # union the CamelCase string tokens, sort -u. The binary carries the master
    # enum plus context-specific subsets; the union is the full recognized-event
    # vocabulary (30 at 2.1.215). Reorder-robust (token match, not position).
    # Fail loud on zero matches (anchor gone = hook schema shape change), mirroring
    # the effort/bool guards above. Tokens are grepped WITH their quotes so each
    # line is already a JSON string literal — jq -s slurps them, no tr needed.
    hookEvents=$("$grep" -aoE '\[[^][]*"PreToolUse"[^][]*\]' "${bin}" \
      | "$grep" -aoE '"[A-Za-z][A-Za-z0-9]*"' | "$sort" -u || true)
    if [ "$(printf '%s\n' "$hookEvents" | "$grep" -c . || true)" -lt 1 ]; then
      echo "claude-extract: no hook-event enum array found (upstream changed the hook schema shape)" >&2
      exit 1
    fi
    hookEventsJson=$(printf '%s\n' "$hookEvents" | "$jq" -s .)

    # Model catalog — the soft enum behind mkClaude.nix's `model` option.
    # Each catalog entry opens `{id:"claude-…",family:"…",display_name:…}`.
    # Anchor on the id+family PAIR, never a bare `id:`, so unrelated minified
    # `id:"…"` sites cannot masquerade as models. The pair also yields ALIAS
    # ids only (claude-opus-5) — never the date-suffixed provider wire ids
    # (claude-opus-4-20250514) carried in the sibling `provider_ids` block,
    # which are not selectable option values.
    #
    # Do NOT reach for `provider_ids.first_party` here. A previous incarnation
    # of this extraction grepped camelCase `firstParty:"claude-…"`; the catalog
    # spells that key snake_case and the only camelCase site in the binary
    # belongs to an unrelated table, so it silently matched a single stray id
    # from 2.1.207 through 2.1.219 and the model option missed the entire
    # Opus 5 / Sonnet 5 / Fable 5 generation.
    catalogIds=$("$grep" -aoE '\{id:"claude-[a-z0-9-]+",family:"[a-z]+"' "${bin}" \
      | "$sed" -E 's/^\{id:"//; s/",family:.*$//' | "$sort" -u || true)
    if [ "$(printf '%s\n' "$catalogIds" | "$grep" -c . || true)" -lt 1 ]; then
      echo "claude-extract: no {id:\"claude-…\",family:\"…\"} model catalog entries found (upstream changed the catalog shape)" >&2
      exit 1
    fi

    # Models with an announced retirement, keyed by the same alias id. They
    # stay in the catalog but are not selectable, so they are subtracted from
    # the option's enum. PRESENCE in the table is the filter — deliberately
    # not a comparison against the retirement date, because reading a
    # build-time clock would make this sidecar non-reproducible.
    retiredIds=$("$grep" -aoE '"claude-[a-z0-9.-]+":\{modelName:"[^"]*",retirementDates:' "${bin}" \
      | "$sed" -E 's/^"//; s/":\{modelName:.*$//' | "$sort" -u || true)
    if [ "$(printf '%s\n' "$retiredIds" | "$grep" -c . || true)" -lt 1 ]; then
      echo "claude-extract: no retirement table found (upstream changed the deprecation shape)" >&2
      exit 1
    fi

    models=$("$comm" -23 \
      <(printf '%s\n' "$catalogIds") \
      <(printf '%s\n' "$retiredIds") || true)
    if [ "$(printf '%s\n' "$models" | "$grep" -c . || true)" -lt 1 ]; then
      echo "claude-extract: every catalog id is marked retired (anchors disagree; refusing to emit an empty model enum)" >&2
      exit 1
    fi

    # Shape assertion. A dead anchor can still match ONE stray id and sail
    # past the non-empty guards above — that is precisely how the camelCase
    # regression survived 12 releases. The committed sidecar's drift check
    # does not catch that either: the update pipeline regenerates the sidecar
    # in the SAME PR, so a collapsed extraction would just be committed as
    # the new truth and the drift check would go green over it.
    #
    # So assert the catalog's shape rather than its size. claude-code has
    # always shipped an opus, a sonnet and a haiku; if any family is missing
    # the anchor is matching the wrong structure. Matching the family token
    # ANYWHERE in the id keeps both naming schemes in play (claude-sonnet-5
    # and the older claude-3-5-sonnet). Should upstream genuinely retire a
    # whole family, this fails loud and a human decides — which is the
    # correct outcome for a change that reshapes the model option.
    #
    # The membership test is a bash `case`, NOT `printf … | grep -q`. Do not
    # "simplify" it back into a pipeline. `grep -q` exits at its FIRST match
    # and closes the read end; bash's printf builtin writes this list roughly
    # a line at a time (strace: 9 write(2) calls for the 12-model set), so the
    # writes after the match land on a closed pipe. printf then exits non-zero
    # ("printf: write error: Broken pipe") and `pipefail` promotes that writer
    # failure to the pipeline's status — so `if !` fires and the guard reports
    # a family that is plainly PRESENT as missing. It is a scheduling race, so
    # it is intermittent, and it is worst for the family matching EARLIEST in
    # the sorted list (`sonnet`, via claude-3-5-sonnet) because that leaves the
    # most unwritten lines behind. `case` has no subprocess and no pipe, so the
    # failure mode cannot occur. Semantics are unchanged: the families are
    # plain lowercase tokens with no regex metacharacters and no newlines, so
    # an unanchored substring match over the whole list is exactly what
    # `grep -q "$family"` computed.
    for family in opus sonnet haiku; do
      case "$models" in
        *"$family"*) ;;
        *)
          echo "claude-extract: no '$family' id among the extracted models (anchor is matching the wrong structure, or upstream dropped the family)" >&2
          # The bare `tr` below is correct: this body is a runCommandLocal
          # build script, so stdenv supplies a full PATH. The marker has to
          # sit ON the offending line — the check filters by line.
          echo "claude-extract: extracted set was: $(printf '%s\n' "$models" | "$sort" | tr '\n' ' ')" >&2 # bare-commands: ok
          exit 1
          ;;
      esac
    done
    modelsJson=$(printf '%s\n' "$models" | "$jq" -R . | "$jq" -s .)

    pinsJson=$(printf '%s\n' "$pins" | "$jq" -R . | "$jq" -s .)
    boolKeysJson=$(printf '%s\n' "''${boolKeys[@]}" | "$sort" -u | "$jq" -R . | "$jq" -s .)
    "$jq" -n --argjson pins "$pinsJson" --argjson levels "$levels" \
      --argjson boolKeys "$boolKeysJson" --argjson hookEvents "$hookEventsJson" \
      --argjson models "$modelsJson" \
      '{launchEffortPins: $pins, effortLevels: $levels, settingsBooleanKeys: $boolKeys, hookEvents: $hookEvents, models: $models}' > "${dest}"
  '';

  # Kiro hook triggers — the northbound soft-enum `knownTriggers`. Unlike Claude,
  # Kiro has NO clean extract-all anchor: its PascalCase trigger names are polluted
  # by the camelCase `ChatTriggerType` telemetry enum + unrelated tokens, so a
  # mkClaudeExtract-style array grep would capture red herrings. Instead PROBE a
  # baked candidate universe (the union of documented v2+v3 triggers) for binary
  # presence — present -> `hookTriggers`, absent -> `documentedAbsent`
  # (doc-ahead-of-binary). Fail loud if NONE present (anchor gone = binary
  # hook-trigger shape change), mirroring mkClaudeExtract's guards. A brand-new
  # trigger absent from the candidate universe is invisible here — the impure
  # docs-diff (deferred) covers that; grow `candidates` from the docs on a new one.
  #   bin:  absolute path to the kiro chat binary (`.kiro-cli-chat-wrapped`).
  #   pkgs: nixpkgs set (gnugrep, coreutils, jq).
  #   dest: output path (default "/dev/stdout"; pass "$out" in runCommand).
  mkKiroExtract = {
    bin,
    pkgs,
    dest ? "/dev/stdout",
  }: ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    grep="${pkgs.gnugrep}/bin/grep"
    jq="${pkgs.jq}/bin/jq"
    sort="${pkgs.coreutils}/bin/sort"
    wc="${pkgs.coreutils}/bin/wc"
    tr="${pkgs.coreutils}/bin/tr"

    # Documented v2+v3 trigger universe: Jun-5 docs (5) + v3 docs (11) + the v2
    # `AgentSpawn` name (v3 maps it -> SessionStart). Alphabetical; grow from docs.
    candidates=(AgentSpawn Manual PostFileCreate PostFileDelete PostFileSave PostTaskExec PostToolUse PreTaskExec PreToolUse SessionStart Stop UserPromptSubmit)

    present=()
    absent=()
    for t in "''${candidates[@]}"; do
      n=$({ "$grep" -aoF "$t" "${bin}" || true; } | "$wc" -l | "$tr" -d ' ')
      if [ "$n" -gt 0 ]; then present+=("$t"); else absent+=("$t"); fi
    done
    if [ "''${#present[@]}" -lt 1 ]; then
      echo "kiro-extract: no documented trigger present in the binary (upstream changed the hook-trigger vocabulary)" >&2
      exit 1
    fi

    hookTriggersJson=$(printf '%s\n' "''${present[@]}" | "$sort" -u | "$jq" -R . | "$jq" -s .)
    if [ "''${#absent[@]}" -gt 0 ]; then
      documentedAbsentJson=$(printf '%s\n' "''${absent[@]}" | "$sort" -u | "$jq" -R . | "$jq" -s .)
    else
      documentedAbsentJson='[]'
    fi
    "$jq" -n --argjson hookTriggers "$hookTriggersJson" --argjson documentedAbsent "$documentedAbsentJson" \
      '{hookTriggers: $hookTriggers, documentedAbsent: $documentedAbsent}' > "${dest}"
  '';

  # Shared body for the sidecar hash fixers below (`mkGoVendorFix`,
  # `mkNpmDepsFix`). Emits a bash function
  # `fix_fod_hash <attrPath> <drvPattern> <sidecarKey>` that builds
  # `<attr>.<attrPath>` through the FLAKE'S OWN `packages` output — so the
  # derivation under test is the one consumers get, overlay stack and all
  # — and, on a fixed-output hash mismatch, writes the scraped `got:` hash
  # back to `sourcesFile` under `sidecarKey`.
  #
  # `drvPattern` is not decoration. A failing `src` — or any other
  # fixed-output derivation on the path — also prints `got:`, and writing
  # THAT into a vendor/deps key produces a plausible-looking WRONG hash
  # that nothing downstream would flag. So a mismatch is only trusted when
  # the message names a derivation matching the pattern.
  #
  # It is a shell FUNCTION rather than an inlined body because the npm
  # shape needs it TWICE in one script: `npmDeps` is downstream of `src`,
  # so a stale `srcHash` makes the `npmDeps` build fail on the SRC
  # mismatch and never reach the deps one. Two sequential invocations,
  # each its own `nix build`, is what lets the second read the sidecar the
  # first just wrote.
  #
  # Runs from the repo root, and the sidecar must be GIT-TRACKED: a flake
  # only sees tracked files, so an untracked sidecar is invisible to the
  # eval this drives.
  #
  #   attr:        name under `packages.<system>` (flake.nix flattens
  #                `pkgs.generic` into it, so a generic package is
  #                reachable by its bare name). This repo has NO
  #                `legacyPackages` output — do not reach for one.
  #   sourcesFile: threaded explicitly by every caller.
  fodHashFixFn = {
    attr,
    pkgs,
    pname,
    sourcesFile,
  }: ''
    fix_fod_hash() {
      local attrPath="$1" drvPattern="$2" key="$3"
      local expr output hash tmp

      # builtins.getAttr keeps the expression free of a brace substitution
      # sequence, so bash never tries to expand any part of it.
      expr="(builtins.getAttr builtins.currentSystem (builtins.getFlake (toString ./.)).packages).${attr}.$attrPath"

      if output=$(${pkgs.nix}/bin/nix build --impure --no-link --expr "$expr" 2>&1); then
        echo "${pname}: $key ok"
        return 0
      fi

      hash=""
      # Here-string, not `echo "$output" | grep -q`. This runs under the
      # enclosing writeShellScript's `set -euETo pipefail`, `$output` is a
      # whole failed `nix build` transcript (tens of KB), and bash's echo
      # builtin writes it a line at a time — so `grep -q` exiting at its first
      # match sends the remaining writes to EPIPE and poisons the pipeline's
      # status even though the match SUCCEEDED. That flips this `if` false,
      # leaves `hash` empty, and reports a real hash mismatch as the unrelated
      # "build failed without a hash mismatch" error below. Measured at 3/200
      # on a 34 KB transcript.
      if ${pkgs.gnugrep}/bin/grep -q "fixed-output derivation '[^']*$drvPattern" <<<"$output"; then
        hash=$(echo "$output" | ${pkgs.gnugrep}/bin/grep -oP 'got:\s+\Ksha256-[A-Za-z0-9+/=]+' | ${pkgs.coreutils}/bin/head -n1 || :)
      fi
      if [ -z "$hash" ]; then
        echo "${pname}: $attrPath build failed without a '$drvPattern' hash mismatch:" >&2
        echo "$output" >&2
        exit 1
      fi

      echo "${pname}: $key -> $hash"
      tmp=$(${pkgs.coreutils}/bin/mktemp)
      ${pkgs.jq}/bin/jq --arg h "$hash" --arg k "$key" '.[$k] = $h' "${sourcesFile}" > "$tmp"
      ${pkgs.coreutils}/bin/mv "$tmp" "${sourcesFile}"
    }
  '';

  # Composed updateScript for packages whose src is a GitHub repo-archive
  # tarball at a release tag (fetchzip consumers): one `repo` value
  # derives BOTH the archive URL template and the version check, so the
  # two can never be pointed at different repositories.
  #
  # `unpack = true` is not optional here: a repo-archive tarball consumed
  # by fetchzip is hashed as the UNPACKED NAR, so a flat-file prefetch
  # hash would be recorded and every consumer would then fail its
  # fixed-output check.
  #
  # Composed over ghLatestVersionCmd and mkUpdateScript below — the set
  # is `rec`, so the entries stay in the group's alphabetical order and
  # definition order carries no meaning.
  # `sourcesFile` is threaded through rather than left to
  # mkUpdateScript's default: the default assumes the sidecar sits at
  # `overlays/<pname>-sources.json`, which is only true of the packages
  # at the overlays/ root. Grouped subtrees (overlays/generic/) keep the
  # sidecar beside the package file and must say so.
  ghArchiveUpdateScript = {
    extraExtract ? "",
    pkgs,
    pname,
    repo,
    sourcesFile ? "overlays/${pname}-sources.json",
    tagPrefix ? "v",
  }:
    mkUpdateScript {
      inherit extraExtract pkgs pname sourcesFile;
      platforms = {
        src = ver: "https://github.com/${repo}/archive/${tagPrefix}${ver}.tar.gz";
      };
      unpack = true;
      versionCheck.cmd = ghLatestVersionCmd {inherit pkgs repo tagPrefix;};
    };

  # Shell command printing the latest GitHub release version, resolved
  # from the releases/latest redirect — no API call, so no token and no
  # rate-limit concerns, and GitHub excludes prereleases/drafts from
  # "latest". tagPrefix is stripped from the tag to yield the bare
  # version (e.g. tagPrefix = "rust-v" turns "rust-v0.145.0" into
  # "0.145.0"). Pair with mkUpdateScript's versionCheck.cmd.
  ghLatestVersionCmd = {
    pkgs,
    repo,
    tagPrefix ? "v",
  }: "${pkgs.curl}/bin/curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/${repo}/releases/latest | ${pkgs.gnused}/bin/sed -n 's|.*/tag/${tagPrefix}\\([0-9][^/]*\\)$|\\1|p'";

  # Resolve the Go toolchain for a package from its DECLARED FLOOR — the
  # `go` (or higher `toolchain`) directive in the package's own go.mod —
  # rather than from a pinned toolchain version.
  #
  #   floor satisfied by our pin  -> `ourGo`, no override, go-bin untouched
  #   floor above our pin         -> the LOWEST go-bin RELEASE that satisfies it
  #   floor above everything      -> throw, naming package, floor and newest
  #
  # WHY A FLOOR AND NOT A PIN. A pinned toolchain rots silently: it cannot
  # tell "still filling a real gap" from "nixpkgs caught up and this is now
  # a DOWNGRADE", and nothing announces the transition. The sibling repo
  # this was ported from demonstrates the failure live — it pins
  # oh-my-posh to Go 1.26.0, which was a gap-filler when written and is a
  # downgrade now that our pin ships 1.26.5. A floor is the durable fact
  # ("this package needs Go >= X"); the toolchain is derived from it.
  #
  # The shape is self-clearing with no timer and no cleanup PR: the moment
  # nixpkgs catches up, this returns `ourGo` and the go-bin path goes cold
  # by itself. It CANNOT EXPRESS A DOWNGRADE by construction. And the
  # requirement it exists for — a package raising its go.mod floor past
  # nixpkgs-unstable — is met automatically on the next eval instead of
  # waiting for a human to notice.
  #
  # Two alternatives were considered and rejected; do not reintroduce
  # either. A 30-day expiry timer fires on the CALENDAR, not on the
  # condition — it nags while the pin is still needed and stays silent
  # when the pin goes bad early. A hard throw once nixpkgs catches up
  # targets the right condition but turns a routine input bump into a red
  # PR a human must clear. go-overlay's own `fromGoMod` selector is also
  # out: it reads the floor from FETCHED SOURCE at eval time, which is
  # import-from-derivation, and this repo already tracks an open defect
  # where exactly that pattern dies under
  # `--option allow-import-from-derivation false`.
  #
  # PRERELEASES ARE FILTERED OUT, and that is load-bearing rather than
  # tidiness. go-bin carries 26 of them (1.17rc1 … 1.27rc2) alongside 127
  # releases, and `go-bin.latest` is currently a PRERELEASE (1.27rc2) —
  # which is one reason the selection resolves against `versions` instead
  # of any moving `latest`/`latestStable` selector. Nix's component
  # comparison also sorts "1.27rc1" ABOVE "1.27.0" (a non-numeric
  # component loses a string compare to a numeric one), so an unfiltered
  # "lowest satisfying" would hand a package an rc toolchain the first
  # time a floor landed on an unreleased minor.
  #
  # Comparison is `lib.versionAtLeast` / `lib.versionOlder` throughout,
  # never string comparison — a string compare gets "1.9.0" vs "1.26.0"
  # backwards.
  #
  #   floor: bare version string from go.mod, e.g. "1.25.0"
  #   goBin: `go-bin` from an ourPkgs carrying go-overlay's overlay
  #   lib:   nixpkgs lib (for the version comparators)
  #   ourGo: `ourPkgs.go` — this repo's pinned toolchain
  #   pname: package name, for the throw message
  goToolchainForFloor = {
    floor,
    goBin,
    lib,
    ourGo,
    pname,
  }:
    if lib.versionAtLeast ourGo.version floor
    then ourGo
    else let
      releases =
        builtins.filter
        (v: builtins.match "[0-9]+\\.[0-9]+(\\.[0-9]+)?" v != null)
        (builtins.attrNames goBin.versions);
      ascending = builtins.sort lib.versionOlder releases;
      satisfying = builtins.filter (v: lib.versionAtLeast v floor) ascending;
      newest =
        if ascending == []
        then "none"
        else lib.last ascending;
    in
      if satisfying == []
      then
        throw ''
          ${pname}: needs Go >= ${floor}, but no toolchain that new is available.
            our nixpkgs pin ships go ${ourGo.version}
            newest go-bin release is ${newest}
          Run `nix flake update go-overlay` to pick up newly published toolchains.''
      else goBin.versions.${builtins.head satisfying};

  # Vendor-hash fixer for buildGoModule packages pinned via a sidecar:
  # builds `<attr>.goModules` through the full flake overlay stack with
  # the sidecar's current vendorHash and, on a hash mismatch, writes the
  # correct hash back to sourcesFile. Runs from the repo root.
  #
  # REQUIRED, not a convenience, because of how mkUpdateScript writes.
  # `buildCandidate` above opens with
  # `jq -n --arg v "$latest" '{version: $v}' > "$tmp"` — the candidate
  # sidecar is built FROM SCRATCH, so any key the writer does not itself
  # produce is DESTROYED on every write. `vendorHash` is exactly such a
  # key. That is why every Go overlay here reads
  # `sources.vendorHash or lib.fakeHash` (the `or` covers the transient
  # mid-update state) and why this runs as `extraExtract`, immediately
  # after the sidecar write.
  #
  # Exposed standalone as `passthru.fixVendorHash` as well, because a
  # nixpkgs or Go-toolchain bump can invalidate vendorHash with no
  # version bump at all, and `extraExtract` only fires on a version bump.
  # `fix_sidecar_hashes` (dev/scripts/update-common.sh) discovers this
  # attr across `packages.<system>` and runs it when an input bump's
  # build verification fails, so that case self-heals into the same
  # commit instead of parking the whole input update as HELD BACK.
  # Until 2026-07-25 that standalone had NO caller at all and this
  # comment claimed a re-run that did not exist — if you unwire
  # `fix_sidecar_hashes`, fix this sentence too.
  #
  # The build-and-scrape body lives in `fodHashFixFn` above; see its
  # header for the argument contract and for why the `-go-modules`
  # derivation-name pattern is load-bearing rather than decorative.
  mkGoVendorFix = {
    attr,
    pkgs,
    pname,
    sourcesFile ? "overlays/${pname}-sources.json",
  }:
    pkgs.writeShellScript "fix-vendor-${pname}" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      ${fodHashFixFn {inherit attr pkgs pname sourcesFile;}}

      fix_fod_hash "goModules" "-go-modules" "vendorHash"
    '';

  # Hash fixer for buildNpmPackage packages pinned via a sidecar. Same
  # role as `mkGoVendorFix` and the same `extraExtract` wiring, but it
  # restores TWO keys, in order: `srcHash` then `npmDepsHash`.
  #
  # Both keys, and not just the deps one, because a `buildNpmPackage`
  # overlay that re-points `src` by OVERRIDING the upstream fetcher
  # (`upstream.src.override { tag; hash; }` — the only way to keep an
  # upstream `postFetch` without restating it) cannot get its src hash
  # from `mkUpdateScript`'s prefetch path. Measured on bruno v4.0.0:
  # `nix-prefetch-url --unpack` of the repo-archive tarball yields
  # sha256-uZswYGMwVfiIG+dNec6mEno05UVbsWlVHoNFadipQlg=, while the
  # fetcher — whose `postFetch` runs `npm-lockfile-fix` over
  # package-lock.json — yields
  # sha256-M4oNx3nSe8hSAtZMVyXIW0qQIQkaOeQgpPsfjmmJ30E=. Recording the
  # prefetch hash would simply fail the consumer's fixed-output check. So
  # such a package passes `platforms = {}` to `mkUpdateScript` — the
  # sidecar then carries the version alone — and lets this restore both
  # hashes immediately afterwards.
  #
  # The order is forced: `npmDeps` is derived FROM `src`
  # (`build-support/node/build-npm-package` threads `src` and the patch
  # hooks into `fetchNpmDeps`), so a stale `srcHash` makes the deps build
  # fail on the SRC mismatch and never reach the deps one.
  #
  # Exposed standalone as `passthru.fixNpmDepsHash` for the same reason
  # its Go sibling is: a nixpkgs-side fetcher or builder change can
  # invalidate either hash with no version bump at all, and the sidecar's
  # version-equality early exit means that case fails LOUDLY on a hash
  # mismatch rather than self-healing.
  mkNpmDepsFix = {
    attr,
    pkgs,
    pname,
    sourcesFile ? "overlays/${pname}-sources.json",
  }:
    pkgs.writeShellScript "fix-npm-deps-${pname}" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      ${fodHashFixFn {inherit attr pkgs pname sourcesFile;}}

      fix_fod_hash "src" "-source" "srcHash"
      fix_fod_hash "npmDeps" "-npm-deps" "npmDepsHash"
    '';

  # Generate an updateScript for per-platform binary packages that use
  # sources.json. Fetches the latest version, prefetches each platform's
  # binary, writes version + per-platform hashes to sourcesFile.
  #
  # alwaysPrefetch: skip the version-equality early exit and prefetch on
  #   EVERY run, then decide whether to write by comparing the freshly
  #   built sidecar against the committed one. Defaults to false, which
  #   leaves every other caller on exactly today's control flow.
  #
  #   For a package whose artifact URL carries its version, the early
  #   exit is free and correct: same version means same URL means same
  #   bytes. For a package whose URL is VERSION-INDEPENDENT it is a
  #   silent-staleness bug — the version string becomes the ONLY change
  #   signal, so upstream re-serving modified content at the same URL
  #   without advancing its version leaves the committed hash stale and
  #   `fetchurl` failing until the version happens to move.
  #   `overlays/generic/dns-root-hints.nix` is the only such consumer
  #   today (InterNIC re-serves one canonical URL; its "version" is a
  #   root-zone serial scraped out of the file body).
  #
  #   COST: one prefetch per opted-in package per sweep, every sweep,
  #   whether or not anything moved. For one small file 4x/day that is
  #   nothing; for a multi-hundred-MB per-platform release asset set it
  #   would not be. That asymmetry is why this is opt-in rather than the
  #   default, and why widening it should be argued per package.
  # versionCheck: { cmd = "curl ..."; } — shell command that prints the version
  # platforms: { "x86_64-linux" = ver: "https://.../${ver}/file.tar.gz"; ... }
  #   An EMPTY set is legal and means "record the version only". Use it
  #   when the package's src hash is not a plain prefetch of a URL — an
  #   overlay that re-points an upstream fetcher carrying a `postFetch`
  #   gets a hash over the POST-postFetch tree, which `nix-prefetch-url`
  #   cannot reproduce. Such a package pairs `platforms = {}` with an
  #   `extraExtract` fixer that scrapes the real hashes out of a build
  #   (see `mkNpmDepsFix`); recording the prefetch hash instead would put
  #   a plausible, wrong value in the sidecar.
  # sourcesFile: path to sources.json relative to repo root
  # extraExtract: extra shell appended after the sources.json write (e.g.
  #   regenerating a committed sidecar from the freshly-bumped binary).
  #   Defaults to "" so callers that don't need it are unaffected.
  # unpack: hash the UNPACKED tarball (`nix-prefetch-url --unpack`) — for
  #   fetchzip consumers of repo-archive tarballs, whose fixed-output hash
  #   is over the unpacked NAR, as opposed to the flat-file hash a
  #   fetchurl consumer wants. Wrong either way round: the prefetch
  #   succeeds and the recorded hash simply fails the consumer's check.
  # pkgs: nixpkgs set (for curl, jq, nix)
  mkUpdateScript = {
    alwaysPrefetch ? false,
    extraExtract ? "",
    pkgs,
    platforms,
    pname,
    sourcesFile ? "overlays/${pname}-sources.json",
    unpack ? false,
    versionCheck,
  }: let
    # Build the candidate sidecar in "$tmp": the version, then one
    # {url, hash} entry per platform. Identical in both modes — the two
    # flows differ only in whether they reach it and what they do with
    # the result — so it is bound once rather than duplicated.
    buildCandidate = ''
      tmp=$(${pkgs.coreutils}/bin/mktemp)
      ${pkgs.jq}/bin/jq -n --arg v "$latest" '{version: $v}' > "$tmp"

      ${builtins.concatStringsSep "\n" (builtins.attrValues (builtins.mapAttrs (system: mkUrl: let
          # Braced so the template stays safe when the next character is a
          # valid identifier char (e.g. "..._''${ver}_amd64.deb" would
          # otherwise expand the undefined "$latest_amd64").
          url = mkUrl "\${latest}";
          # URLs with %20 need --name to avoid an illegal store name
          nameArg =
            if builtins.match ".*%20.*" url != null
            then "--name ${pname}-prefetch"
            else "";
          unpackArg =
            if unpack
            then "--unpack"
            else "";
        in ''
          url="${url}"
          prefetched=$(${pkgs.nix}/bin/nix-prefetch-url --type sha256 ${unpackArg} ${nameArg} "$url")
          hash=$(${pkgs.nix}/bin/nix hash convert --to sri --hash-algo sha256 "$prefetched")
          ${pkgs.jq}/bin/jq --arg sys "${system}" --arg u "$url" --arg h "$hash" \
            '. + {($sys): {url: $u, hash: $h}}' "$tmp" > "''${tmp}.new" && ${pkgs.coreutils}/bin/mv "''${tmp}.new" "$tmp"
        '')
        platforms))}
    '';

    commitCandidate = ''
      ${pkgs.coreutils}/bin/mv "$tmp" "${sourcesFile}"
      echo "Updated ${sourcesFile}"
      ${extraExtract}
    '';

    # Default flow — the pre-alwaysPrefetch control flow, unchanged.
    # Version equality means "nothing moved", which is true for every
    # package whose artifact URL carries its version.
    defaultFlow = ''
      if [ "$latest" = "$current" ]; then
        echo "${pname}: already at $current"
        exit 0
      fi

      echo "${pname}: $current -> $latest"
      ${buildCandidate}
      ${commitCandidate}
    '';

    # Always-prefetch flow — the prefetch IS the change detector.
    alwaysFlow = ''
      # No version-equality early exit: for this package the version is
      # not a reliable change signal (see `alwaysPrefetch` in the header),
      # so the only way to learn whether upstream moved is to fetch and
      # hash it.
      ${buildCandidate}

      # Compare NORMALIZED (jq -S), so key order or whitespace in the
      # committed file cannot masquerade as a change. The version half and
      # the everything-else (hash) half are compared separately only so
      # the message below can name what actually moved; together they
      # cover the whole document.
      newHashes=$(${pkgs.jq}/bin/jq -S 'del(.version)' "$tmp")
      oldHashes=$(${pkgs.jq}/bin/jq -S 'del(.version)' "${sourcesFile}")

      if [ "$latest" = "$current" ] && [ "$newHashes" = "$oldHashes" ]; then
        # Deliberately does NOT write. An unconditional mv would churn the
        # file's mtime on every sweep and hand the update pipeline an
        # empty diff to try to commit.
        ${pkgs.coreutils}/bin/rm -f "$tmp"
        echo "${pname}: already at $current (version and hashes unchanged)"
        exit 0
      fi

      # Deferred until after the comparison on purpose. The default flow
      # announces "$current -> $latest" BEFORE prefetching, which here
      # would read "X -> X" whenever only the hash moved — the exact case
      # this mode exists to catch.
      if [ "$latest" != "$current" ] && [ "$newHashes" != "$oldHashes" ]; then
        echo "${pname}: version and hash moved: $current -> $latest"
      elif [ "$latest" != "$current" ]; then
        echo "${pname}: version moved: $current -> $latest"
      else
        echo "${pname}: hash moved at unchanged version $current (upstream re-served the same URL)"
      fi
      ${commitCandidate}
    '';
  in
    pkgs.writeShellScript "update-${pname}" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      latest=$(${versionCheck.cmd})
      if [ -z "$latest" ]; then
        echo "${pname}: failed to fetch latest version" >&2
        exit 1
      fi

      current=$(${pkgs.jq}/bin/jq -r '.version' "${sourcesFile}")
      ${
        if alwaysPrefetch
        then alwaysFlow
        else defaultFlow
      }
    '';
}
