# overlays/lib.nix — DRY version extraction + smoke test helpers.
#
# Each helper reads a manifest from a Nix store path (src) at eval
# time and returns the upstream version string. Callers combine it
# with `builtins.substring 0 7 rev` to produce "x.y.z+abc1234".
{
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
        if echo "$output" | grep -Fq "${marker}"; then
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
      set -eu
      new_rev=$(${pkgs.git}/bin/git ls-remote "${url}" HEAD | cut -f1)
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
  # and the workflow/ultracode boolean settings keys we depend on, emitting
  # `{launchEffortPins, effortLevels, settingsBooleanKeys}` to `dest`
  # (default stdout). Single source of the grep logic — used by
  # claude-code.nix's passthru.extracted (and, transitively, by
  # mkUpdateScript). Fails loud (exit 1) if the pin grep is empty, the
  # effort anchor != exactly one match, or any tracked boolean settings key
  # is missing/renamed — so an upstream change breaks the build instead of
  # silently extracting nothing.
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
  #   pkgs: nixpkgs set (gnugrep, coreutils, jq).
  #   dest: output path (default "/dev/stdout"; pass "$out" in runCommand).
  mkClaudeExtract = {
    bin,
    pkgs,
    dest ? "/dev/stdout",
  }: ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    grep="${pkgs.gnugrep}/bin/grep"
    jq="${pkgs.jq}/bin/jq"
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

    pinsJson=$(printf '%s\n' "$pins" | "$jq" -R . | "$jq" -s .)
    boolKeysJson=$(printf '%s\n' "''${boolKeys[@]}" | "$sort" -u | "$jq" -R . | "$jq" -s .)
    "$jq" -n --argjson pins "$pinsJson" --argjson levels "$levels" \
      --argjson boolKeys "$boolKeysJson" --argjson hookEvents "$hookEventsJson" \
      '{launchEffortPins: $pins, effortLevels: $levels, settingsBooleanKeys: $boolKeys, hookEvents: $hookEvents}' > "${dest}"
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

  # Generate an updateScript for per-platform binary packages that use
  # sources.json. Fetches the latest version, prefetches each platform's
  # binary, writes version + per-platform hashes to sourcesFile.
  #
  # versionCheck: { cmd = "curl ..."; } — shell command that prints the version
  # platforms: { "x86_64-linux" = ver: "https://.../${ver}/file.tar.gz"; ... }
  # sourcesFile: path to sources.json relative to repo root
  # extraExtract: extra shell appended after the sources.json write (e.g.
  #   regenerating a committed sidecar from the freshly-bumped binary).
  #   Defaults to "" so callers that don't need it are unaffected.
  # pkgs: nixpkgs set (for curl, jq, nix)
  mkUpdateScript = {
    pname,
    versionCheck,
    platforms,
    sourcesFile ? "overlays/${pname}-sources.json",
    extraExtract ? "",
    pkgs,
  }:
    pkgs.writeShellScript "update-${pname}" ''
      set -eu
      latest=$(${versionCheck.cmd})
      [ -z "$latest" ] && echo "Failed to fetch latest version" >&2 && exit 1

      current=$(${pkgs.jq}/bin/jq -r '.version' "${sourcesFile}")
      if [ "$latest" = "$current" ]; then
        echo "${pname}: already at $current"
        exit 0
      fi

      echo "${pname}: $current -> $latest"
      tmp=$(mktemp)
      ${pkgs.jq}/bin/jq -n --arg v "$latest" '{version: $v}' > "$tmp"

      ${builtins.concatStringsSep "\n" (builtins.attrValues (builtins.mapAttrs (system: mkUrl: let
          url = mkUrl "$latest";
          # URLs with %20 need --name to avoid illegal store name
          nameArg =
            if builtins.match ".*%20.*" url != null
            then "--name ${pname}.dmg"
            else "";
        in ''
          url="${mkUrl "\$latest"}"
          hash=$(${pkgs.nix}/bin/nix hash convert --to sri --hash-algo sha256 \
            "$(${pkgs.nix}/bin/nix-prefetch-url --type sha256 ${nameArg} "$url" 2>/dev/null)")
          ${pkgs.jq}/bin/jq --arg sys "${system}" --arg u "$url" --arg h "$hash" \
            '. + {($sys): {url: $u, hash: $h}}' "$tmp" > "''${tmp}.new" && mv "''${tmp}.new" "$tmp"
        '')
        platforms))}

      mv "$tmp" "${sourcesFile}"
      echo "Updated ${sourcesFile}"
      ${extraExtract}
    '';
}
