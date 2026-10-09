rec {
  # Extract the claude-code facts that mkClaude.nix's option surface is built
  # from, emitting `{effortLevels, hookEvents, launchEffortPins, models,
  # settings, settingsBooleanKeys}` to `dest` (default stdout). Single source of
  # the extraction logic — used by claude-code.nix's passthru.extracted (and,
  # transitively, by mkUpdateScript's extraExtract).
  #
  # TWO mechanisms, and the split is the whole design:
  #
  #   1. The SETTINGS SCHEMA comes from the binary describing ITSELF.
  #      `bununpack.py` unpacks the Bun single-exec's module graph; `census.mjs`
  #      imports the settings chunk out of that graph and calls the binary's OWN
  #      schema builder, its OWN zod -> JSON-Schema converter and its OWN
  #      `@internal` filter. Nothing about the settings surface is grepped,
  #      guessed or curated, so a key upstream adds arrives with the package
  #      bump instead of waiting for a human to notice it. `effortLevels`,
  #      `hookEvents` and `settingsBooleanKeys` are read out of that same schema
  #      — all three used to be greps against the minified bundle, and the
  #      `settingsBooleanKeys` grep is precisely what broke at 2.1.245 when
  #      upstream code-split the bundle out from under its anchor.
  #
  #   2. `launchEffortPins` and `models` are STILL greps, because neither is in
  #      the settings schema: the pins are local-config keys and the model
  #      catalog is a separate module. Their anchors carry a lot of scar tissue;
  #      it is documented inline below and must not be trimmed.
  #
  # Every guard is a hard failure, never a warning. EVERY key here becomes an
  # option surface in mkClaude.nix, so a dead anchor does not merely lose data:
  # it puts the HM/devenv module options out of sync with the binary they are
  # supposed to describe. That is also why the emitted sidecar is committed and
  # drift-checked.
  #
  # The `settingsBooleanKeys` guard covers `ultracode` (persisted via
  # ai.claude.ultracodeOnLaunch), `enableWorkflows` and
  # `workflowKeywordTriggerEnabled`, which the module writes by name. Asserting
  # that the binary's own schema still types all three as booleans on each bump
  # converts a future silent drop into a loud update-pipeline (and
  # `nix flake check` drift-check) failure. Unlike the grep it replaces, the
  # array is now a DISCOVERY rather than the input list echoed back: census.mjs
  # filters those three names by the type the schema actually gives them, so a
  # retype shortens the array.
  #
  #   assets: the packages/claude-code/extract/ directory — bununpack.py, census.mjs
  #           and locate.mjs. Passed as a path so the scripts ride the
  #           derivation's inputs rather than being interpolated into this
  #           string.
  #   bin:  absolute path to the claude binary.
  #   pkgs: nixpkgs set (gnugrep, gnused, coreutils, jq).
  #   dest: output path (default "/dev/stdout"; pass "$out" in runCommand).
  #
  # The BUILD must also supply `python3`, `nodejs_24` and `jq` on PATH — see
  # packages/claude-code/packages/ai/claude-code/package.nix's nativeBuildInputs. nodejs_24 specifically:
  # census.mjs drives `node:module`'s `registerHooks`, which needs Node >= 22.15.
  mkClaudeExtract = {
    assets,
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

    # Establish READABILITY once, before any anchor runs. Every guard below
    # tolerates a grep exit of 1 ("no match") because that is a real verdict
    # each one turns into its own diagnostic — but grep also exits 2 when it
    # cannot READ the file, and a blanket `|| true` collapses the two into one
    # outcome. That is exactly how mkKiroExtract once announced a hook-trigger
    # vocabulary change for a binary it had never opened (see the ifd-patterns
    # fragment, "Separate LOCATING the artifact from PROBING it"). Checking the
    # single fixed path up front means the `|| true`s below can only ever be
    # hiding an absent anchor, which is what they are for.
    if [ ! -r "${bin}" ]; then
      echo "claude-extract: cannot read ${bin} — this is a LOCATION failure, nothing was probed (the package layout moved)" >&2
      exit 1
    fi

    pins=$("$grep" -aoE 'unpin[A-Za-z0-9]+LaunchEffort' "${bin}" | "$sort" -u || true)
    if [ -z "$pins" ]; then
      echo "claude-extract: no unpin*LaunchEffort keys found (upstream renamed the launch-pin mechanism)" >&2
      exit 1
    fi

    # ── The settings schema, from the binary's own emitter ─────────────────
    #
    # Unpack the Bun module graph, then let census.mjs import the settings
    # chunk and run the binary's own schema pipeline over it. Both steps are
    # CONTENT-located: nothing here names a chunk file, a minified identifier or
    # a byte offset, because macOS and Linux builds of one version agree on none
    # of those. (Measured at 2.1.245: the two platforms' censuses are
    # byte-identical, which is the only reason ONE sidecar can be committed for
    # both.)
    #
    # bununpack.py prints its graph summary on stdout; send it to stderr so it
    # cannot contaminate a `dest` of /dev/stdout.
    python3 "${assets}/bununpack.py" "${bin}" ./unpacked >&2 # bare-commands: ok
    node "${assets}/census.mjs" ./unpacked --legacy --out ./census.json # bare-commands: ok

    # Non-empty guard. The census can only fail loud OR return a schema; what it
    # must never do is return a nearly-empty one that gets committed as the new
    # truth. The update pipeline regenerates this sidecar in the SAME PR as the
    # bump, so the drift check would go green over a collapsed extraction — the
    # same blind spot the model-catalog shape assertion below exists for. 160
    # public keys at 2.1.245; the floor is a deliberate fraction of that.
    publicKeyCount=$("$jq" '.settings.publicKeys | length' ./census.json)
    if [ "$publicKeyCount" -lt 100 ]; then
      echo "claude-extract: the settings census produced only $publicKeyCount public keys (expected >= 100) — the schema builder ran but returned almost nothing" >&2
      exit 1
    fi

    # census.mjs emits `null` rather than a guess for a legacy key whose anchor
    # in the schema is gone, so a type test is the guard.
    if [ "$("$jq" -r '.legacy.effortLevels | type' ./census.json)" != "array" ]; then
      echo "claude-extract: the settings schema carries $("$jq" -r '.legacy.effortLevelEnumsSeen' ./census.json) distinct effortLevel enums (expected exactly 1; upstream changed the validator)" >&2
      exit 1
    fi
    if [ "$("$jq" -r '.legacy.hookEvents | type' ./census.json)" != "array" ]; then
      echo "claude-extract: the settings schema no longer pins the hooks record's key vocabulary (upstream changed the hook schema shape)" >&2
      exit 1
    fi

    # A SHORT array means one of the three guarded boolean keys was renamed,
    # dropped, or retyped — census.mjs filters its three names by the type the
    # emitted schema gives them. The names live there, once, and are
    # deliberately not restated here.
    boolKeysJson=$("$jq" -c '.legacy.settingsBooleanKeys' ./census.json)
    if [ "$("$jq" '.legacy.settingsBooleanKeys | length' ./census.json)" -ne 3 ]; then
      echo "claude-extract: the workflow/ultracode boolean settings keys no longer all parse as booleans in the binary's own settings schema — got $boolKeysJson (expected 3)" >&2
      exit 1
    fi

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
          # The bare `tr` below is correct: this body is a runCommand build
          # script, so stdenv supplies a full PATH. The marker has to sit ON
          # the offending line — the check filters by line.
          echo "claude-extract: extracted set was: $(printf '%s\n' "$models" | "$sort" | tr '\n' ' ')" >&2 # bare-commands: ok
          exit 1
          ;;
      esac
    done
    modelsJson=$(printf '%s\n' "$models" | "$jq" -R . | "$jq" -s .)
    pinsJson=$(printf '%s\n' "$pins" | "$jq" -R . | "$jq" -s .)

    # `-S` (sort keys, recursively) so the committed file has one canonical
    # shape regardless of the order the census walked the schema in. Safe for
    # the drift check either way: it compares with `$a == $b`, which ignores
    # object key order and honours array order — and every array here is
    # already byte-sorted by the census or by `sort`.
    "$jq" -S -n \
      --argjson models "$modelsJson" \
      --argjson pins "$pinsJson" \
      --slurpfile census ./census.json \
      '{
         effortLevels: $census[0].legacy.effortLevels,
         hookEvents: $census[0].legacy.hookEvents,
         launchEffortPins: $pins,
         models: $models,
         settings: $census[0].settings,
         settingsBooleanKeys: $census[0].legacy.settingsBooleanKeys,
       }' > "${dest}"
  '';
}
