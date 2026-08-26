# Unrecognized-key check for a runtime's freeform native-settings tree.
#
# Destined for `lib/ai/unrecognizedSettings.nix`. Pure `lib` — no `pkgs`, no
# IFD, no derivations — so it evaluates in `checks/module-eval.nix` and in the
# options-doc eval unchanged.
#
# WHY THIS EXISTS
#
# `ai.<runtime>.nativeSettings` carries a freeform JSON tail on purpose: a key
# upstream ships today must be settable today, without waiting for a typed
# option. The cost of that tail is that a TYPO is indistinguishable from a
# brand-new key — both are "some attr the module does not model" — and Claude
# silently ignores an unknown settings key, so a misspelling is a change that
# appears to apply and does nothing.
#
# The packaged binary now hands us its own settings schema (extracted into
# overlays/claude-code-extracted.json, `settings.paths`). That turns the
# freeform tail from unknowable into merely undeclared: a key is either
# declared by the binary, or the consumer has said "I know, let it through".
#
# WHAT IT IS NOT
#
# A typo catcher, not a validator. It checks KEY NAMES only — never types,
# enums, or required-ness — and it is deliberately permissive at every point
# where the schema stops telling us things (see `walk`).
{lib}: let
  inherit (builtins) attrNames elemAt isAttrs isList length stringLength substring;

  # ── Path grammar ─────────────────────────────────────────────────────────
  #
  # A declared path is dotted; `*` stands for a user-chosen map key and `[]`
  # for an array element (`allowedMcpServers[].serverName`). An emitter that
  # disambiguates anyOf branches appends `|<n>` to a segment
  # (`extraKnownMarketplaces.*.source|0.url`); we UNION the branches by
  # stripping that marker, because a key-name check has no business picking a
  # branch — a key that any branch declares is a key the binary accepts.
  digits = ["0" "1" "2" "3" "4" "5" "6" "7" "8" "9"];
  dropLeadingDigits = s:
    if s != "" && builtins.elem (substring 0 1 s) digits
    then dropLeadingDigits (substring 1 (stringLength s - 1) s)
    else s;
  stripBranches = p: let
    parts = lib.splitString "|" p;
  in
    if length parts == 1
    then p
    else lib.concatStrings ([(builtins.head parts)] ++ map dropLeadingDigits (builtins.tail parts));

  # `options[]` is two steps: the key `options`, then its array element.
  expandSeg = s:
    if s == "[]"
    then ["[]"]
    else if lib.hasSuffix "[]" s
    then expandSeg (lib.removeSuffix "[]" s) ++ ["[]"]
    else [s];
  splitPath = p: lib.concatMap expandSeg (lib.splitString "." (stripBranches p));

  # Segments back to a display path. `[]` glues onto the segment before it.
  renderPath = lib.foldl' (
    acc: s:
      if s == "[]"
      then acc + "[]"
      else if acc == ""
      then s
      else acc + "." + s
  ) "";

  # ── Trie ─────────────────────────────────────────────────────────────────
  #
  # Every declared path is inserted segment-by-segment, so INTERMEDIATE nodes
  # exist even when the emitter never listed them on their own. That matters:
  # 2.1.245 lists `modelPricing.overrides.*.input` but never
  # `modelPricing.overrides.*`, and the wildcard step has to be there anyway.
  insertPath = node: segs:
    if segs == []
    then node
    else let
      h = builtins.head segs;
    in
      node // {${h} = insertPath (node.${h} or {}) (builtins.tail segs);};

  literalChildren = node: builtins.filter (k: k != "*" && k != "[]") (attrNames node);

  # ── Levenshtein, for "did you mean" ──────────────────────────────────────
  #
  # Only ever forced from inside a FAILING assertion's message, so its cost is
  # paid on the path that was going to abort the eval regardless.
  levenshtein = a: b: let
    ca = lib.stringToCharacters a;
    cb = lib.stringToCharacters b;
    la = length ca;
    lb = length cb;
    stepRow = prev: i:
      lib.foldl' (
        acc: j: let
          cost =
            if elemAt ca (i - 1) == elemAt cb (j - 1)
            then 0
            else 1;
        in
          acc
          ++ [
            (lib.min (elemAt prev j + 1)
              (lib.min (lib.last acc + 1) (elemAt prev (j - 1) + cost)))
          ]
      ) [i] (lib.range 1 lb);
  in
    if la == 0
    then lb
    else if lb == 0
    then la
    else lib.last (lib.foldl' stepRow (lib.genList (i: i) (lb + 1)) (lib.range 1 la));

  suggestFor = key: candidates: let
    n = stringLength key;
    threshold =
      if n <= 4
      then 1
      else if n <= 8
      then 2
      else 3;
    # Length prefilter: an edit distance of d needs |len difference| <= d.
    near =
      builtins.filter (
        c: let
          d = stringLength c - n;
        in
          (
            if d < 0
            then -d
            else d
          )
          <= threshold
      )
      candidates;
    scored =
      map (c: {
        name = c;
        d = levenshtein (lib.toLower key) (lib.toLower c);
      })
      near;
    best =
      lib.foldl' (
        acc: s:
          if s.d <= threshold && (acc == null || s.d < acc.d)
          then s
          else acc
      )
      null
      scored;
  in
    if best == null
    then null
    else best.name;
in rec {
  # Build the lookup structure once per (declared) sidecar.
  #
  # `declared` is the sidecar's `settings` record:
  #   { publicKeys = [...]; internalKeys = [...]; paths = { "<dotted>" = {...}; }; }
  #
  # Top-level names are the UNION of the three sources. `paths` is expected to
  # carry both public and @internal keys, but taking the union means a sidecar
  # that ever emits `paths` for public keys only still accepts an @internal key
  # (degraded to freeform rather than rejected) instead of failing a consumer's
  # eval over an extraction detail.
  mkIndex = declared: let
    fromPaths = lib.foldl' (acc: p: insertPath acc (splitPath p)) {} (attrNames (declared.paths or {}));
    topLevel = (declared.publicKeys or []) ++ (declared.internalKeys or []);
  in
    lib.genAttrs topLevel (_: {}) // fromPaths;

  # Walk a settings value against the index.
  #
  # Returns [{ path; patternPath; siblings; }] for every key the binary does
  # not declare. Descent stops AT the offending key — one report per typo, not
  # one per leaf underneath it.
  #
  # The three permissiveness rules, in the order they apply:
  #
  #  1. A container with a `*` child accepts ANY key and descends into the `*`
  #     subtree. This is what keeps `modelPricing.overrides.<model-id>` and
  #     `extraKnownMarketplaces.<name>` from being flagged.
  #
  #  2. A container with NO declared children at all is FREEFORM: accept
  #     everything beneath it and stop. This is what keeps `hooks.<EventName>`,
  #     `env.<VAR>`, `skillOverrides.<skill>`, `enabledPlugins`,
  #     `pluginConfigs`, `modelOverrides` and `vimInsertModeRemaps` from being
  #     flagged. Measured against the 2.1.245 schema: every one of the 17
  #     childless object containers is genuinely open (none carries
  #     additionalProperties:false), so this rule costs no real strictness
  #     today — and it is the only rule available, since the sidecar contract
  #     deliberately drops `additionalProperties`.
  #
  #  3. A container WITH declared children is closed for checking, whether or
  #     not the schema says additionalProperties:false. `permissions` is the
  #     motivating case: upstream tolerates extra keys there, and we do not —
  #     a typo three levels inside `permissions` is exactly what this check is
  #     for.
  #
  # A list descends only when the index has an `[]` child; otherwise it is a
  # leaf value (`permissions.allow`) and there is nothing to check.
  findUnrecognized = index: value: let
    walk = node: concrete: pattern: v:
      if isList v
      then
        (
          if node ? "[]"
          then lib.concatMap (e: walk node."[]" (concrete ++ ["[]"]) (pattern ++ ["[]"]) e) v
          else []
        )
      else if isAttrs v && !(lib.isDerivation v)
      then
        (
          if node == {}
          then []
          else
            lib.concatMap (
              k:
                if node ? ${k}
                then walk node.${k} (concrete ++ [k]) (pattern ++ [k]) v.${k}
                else if node ? "*"
                then walk node."*" (concrete ++ [k]) (pattern ++ ["*"]) v.${k}
                else [
                  {
                    path = renderPath (concrete ++ [k]);
                    patternPath = renderPath (pattern ++ [k]);
                    key = k;
                    siblings = literalChildren node;
                  }
                ]
            ) (attrNames v)
        )
      else [];
  in
    walk index [] [] value;

  # Why an allowlist entry no longer does anything:
  #   "declared" — the binary declares this path now.
  #   "freeform" — it sits under a container the check never inspects.
  #   null       — it is still load-bearing.
  entryStatus = index: entry: let
    go = node: segs:
      if segs == []
      then "declared"
      else if node == {}
      then "freeform"
      else let
        h = builtins.head segs;
      in
        if node ? ${h}
        then go node.${h} (builtins.tail segs)
        else if node ? "*"
        then go node."*" (builtins.tail segs)
        else null;
  in
    go index (splitPath entry);

  # The whole check, as a list of `assertions` entries. Identical on both
  # backends by construction — call it once from each projection's mkMerge.
  #
  # Arguments:
  #   declared    sidecar `settings` record, or null when the sidecar predates
  #               settings extraction (see the "no schema" assertion below)
  #   settings    the settings tree actually written — pass
  #               `filterNulls cfg.nativeSettings`, not the raw option, so a
  #               typed option whose default is null never reports itself
  #   allowed     cfg.allowUnrecognizedSettings
  #   optionPath / allowOptionPath   fully-qualified option names, for messages
  #   version     package version string or null, for messages
  #   notes       { "<top-level key>" = "<extra sentence>"; } — call-site
  #               guidance folded into the report for keys the MODULE itself
  #               writes, or keys that are a known mis-assignment. Rendered
  #               verbatim under the offending key.
  mkAssertions = {
    declared,
    settings,
    allowed,
    optionPath,
    allowOptionPath,
    version ? null,
    notes ? {},
  }: let
    versionSuffix =
      if version == null
      then ""
      else " ${version}";
    index = mkIndex declared;
    findings = findUnrecognized index settings;
    isAllowed = f: builtins.elem f.path allowed || builtins.elem f.patternPath allowed;
    unrecognized = builtins.filter (f: !(isAllowed f)) findings;
    nUnrecognized = length unrecognized;

    describe = f: let
      suggestion = suggestFor f.key f.siblings;
      note = notes.${lib.head (lib.splitString "." f.path)} or null;
    in
      "  - ${f.path}"
      + lib.optionalString (suggestion != null)
      "\n      did you mean `${renderPath (lib.init (splitPath f.path) ++ [suggestion])}`?"
      + lib.optionalString (note != null) "\n      ${note}";

    staleEntries =
      builtins.filter (e: e.status != null)
      (map (e: {
          entry = e;
          status = entryStatus index e;
        })
        allowed);
    nStale = length staleEntries;
    describeStale = s:
      "  - `${s.entry}`: "
      + (
        if s.status == "declared"
        then "the packaged claude-code binary${versionSuffix} declares this key now."
        else
          "sits under a freeform container this check never inspects,\n"
          + "    so it never suppressed anything."
      );
  in [
    # The check silently doing nothing is worse than the check being absent,
    # because an allowlist entry is a consumer saying "I know this one is
    # unchecked" — which is a lie if the checker never ran. Fail loudly
    # rather than degrading quietly.
    {
      assertion = declared != null || allowed == [];
      message = ''
        ${allowOptionPath} is set, but the packaged claude-code's extracted
        sidecar carries no settings schema, so the unrecognized-key check is not
        running and those entries suppress nothing.

        Either update the package (whose overlays/claude-code-extracted.json
        then carries a `settings` record), or drop ${allowOptionPath}.
      '';
    }
    {
      assertion = declared == null || unrecognized == [];
      message = ''
        ${optionPath}: ${toString nUnrecognized} ${
          if nUnrecognized == 1
          then "key is"
          else "keys are"
        } not declared by the packaged
        claude-code binary${versionSuffix}, and not allowlisted:

        ${lib.concatMapStringsSep "\n" describe unrecognized}

        Claude IGNORES an unknown settings key silently, so a misspelling here
        looks applied and does nothing. Two ways forward:

          1. It is a typo — fix the key.

          2. It is real, and newer than this package's extracted schema. Then

               ${allowOptionPath} = [
        ${lib.concatMapStringsSep "\n" (f: "           \"${f.path}\"") unrecognized}
               ];

             writes it through untouched. A `*` segment is accepted in place of
             a key you chose yourself, so one entry can cover every instance.

        The declared set comes from overlays/claude-code-extracted.json, which is
        generated from the binary's own settings schema — never hand-curated. If
        the key is real and the sidecar is stale, REGENERATING THE SIDECAR is the
        durable fix; an allowlist entry is a per-key opt-out of this check that
        lasts until you delete it.
      '';
    }
    {
      assertion = declared == null || staleEntries == [];
      message = ''
        ${allowOptionPath}: ${toString nStale} ${
          if nStale == 1
          then "entry suppresses"
          else "entries suppress"
        } nothing. Delete ${
          if nStale == 1
          then "it"
          else "them"
        }:

        ${lib.concatMapStringsSep "\n" describeStale staleEntries}

        This is a hard failure rather than a warning because a stale entry is not
        inert — it is a standing per-key opt-out of this check. Leave it in place
        and, the day upstream renames or drops that key, your setting goes
        silently dead: the exact failure this check exists to catch, re-opened
        for the one key you had already had trouble with. It is also a one-line
        fix, and it surfaces in the package-bump PR that caused it, which is
        where it is cheapest to deal with.
      '';
    }
  ];
}
