rec {
  # Extract the claude-code facts that mkClaude.nix's option surface is built
  # from, emitting `{effortLevels, hookEvents, launchEffortPins, models,
  # settings}` to `dest` (default stdout). Single source of the extraction
  # logic — used by claude-code's passthru.extracted and the PR CI
  # owner check's regenerator.
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
  #   2. `launchEffortPins` and `models` come from content-located AST reads
  #      of the launch guards, catalog array and retirement table in that graph.
  #      No chunk names or provider wire ids enter the model option enum.
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
  #   pkgs: nixpkgs set (jq, typescript_5).
  #   dest: output path (default "/dev/stdout"; pass "$out" in runCommand).
  #
  # The BUILD must also supply `python3` and `nodejs_24` on PATH — see
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
    jq="${pkgs.jq}/bin/jq"

    # Establish READABILITY before unpacking or locating any facts. A missing
    # artifact is a LOCATION failure, never evidence of a changed vocabulary.
    if [ ! -r "${bin}" ]; then
      echo "claude-extract: cannot read ${bin} — this is a LOCATION failure, nothing was probed (the package layout moved)" >&2
      exit 1
    fi

    # ── The settings schema, from the binary's own emitter ─────────────────
    #
    # Unpack the Bun module graph, then let census.mjs import the settings
    # chunk and run the binary's own schema pipeline over it. Both steps are
    # CONTENT-located: nothing here names a chunk file, a minified identifier or
    # a byte offset, because macOS and Linux builds of one version agree on none
    # of those. (Measured at 2.1.245 and again at 2.1.296: the two platforms'
    # censuses are byte-identical, so the committed facts carry no fork and
    # merge without a decision row.)
    #
    # bununpack.py prints its graph summary on stdout; send it to stderr so it
    # cannot contaminate a `dest` of /dev/stdout.
    python3 "${assets}/bununpack.py" "${bin}" ./unpacked >&2 # bare-commands: ok
    node "${assets}/census.mjs" ./unpacked --legacy --typescript ${pkgs.typescript_5}/lib/node_modules/typescript/lib/typescript.js --out ./census.json # bare-commands: ok

    # Non-empty guard. The census can only fail loud OR return a schema; what it
    # must never do is return a nearly-empty one that gets committed as the new
    # truth. PR CI regenerates this sidecar on the bump PR, so the drift check
    # would go green over a collapsed extraction — the
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

    # `-S` (sort keys, recursively) so the committed file has one canonical
    # shape regardless of the order the census walked the schema in. Safe for
    # the drift check either way: it compares with `$a == $b`, which ignores
    # object key order and honours array order — and every array here is
    # already byte-sorted by the census.
    "$jq" -S -n \
      --slurpfile census ./census.json \
      '{
         effortLevels: $census[0].legacy.effortLevels,
         hookEvents: $census[0].legacy.hookEvents,
         launchEffortPins: $census[0].legacy.launchEffortPins,
         models: $census[0].legacy.models,
         settings: $census[0].settings,
       }' > "${dest}"
  '';
}
