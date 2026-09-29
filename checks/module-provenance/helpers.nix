{
  lib,
  harness,
  ...
}: let
  inherit (harness) harnessNames;

  # ── The A1 backstop: no module in THIS repo may define a ROOT ai.* option ──
  #
  # THE RULE: a root `ai.*` option may be defined only by the module that
  # DECLARES it. Every other module here writes `ai.<runtime>.<option>`; the
  # root level belongs to consumers.
  #
  # Root options belong to consumers as portable defaults. A package-level
  # contribution there silently fans out to every capable runtime, including
  # runtimes the package does not own. Consumers can now retract an individual
  # key per runtime, but they should not have to undo package wiring that landed
  # at the wrong scope. That is why this remains enforced rather than reviewed
  # for.
  #
  # ── Why PROVENANCE and not a source scan ──
  #
  # The design record (plan §A1) specified a regex scan over `lib/**` and
  # `packages/*/modules/**`, and rejected provenance in one line: "an inline
  # module reports `<unknown-file>`, indistinguishable from a consumer's inline
  # config". True, and it points the WRONG WAY — `<unknown-file>` IS the
  # consumer, and the consumer is exactly who may write root options.
  #
  # A scan was built first and measured to miss whole classes of write, among
  # them shapes this repo itself uses: `config.ai.<pool> = …`; a value moved to
  # the next line, which is what alejandra emits for long assignments; and the
  # interpolated `ai.<runtime>.<pool>` form used by `mkBackendTransform.nix` and
  # `packages/semble/modules/common.nix`. Dynamic construction (`lib.genAttrs`,
  # `builtins.listToAttrs`) is UNDECIDABLE in a regex — a permanent hole rather
  # than a fixable bug. All of it is caught here for free, because this runs
  # AFTER evaluation: by then there is no syntax left, only definitions and the
  # files they came from.
  #
  # ── Why "not the declaring module" rather than a file allowlist ──
  #
  # An option's DEFAULT is itself a definition, attributed to the file that
  # DECLARED the option. Measured: an option declared in a file and never
  # written still reports one definition, blamed on that file. A hardcoded
  # allowlist of `sharedOptions.nix` therefore did not exempt what its comment
  # claimed — it masked the synthetic default-definitions, and it would have
  # reported a root option declared in any OTHER file as a violation purely for
  # having a default.
  #
  # Comparing against `opt.declarations` fixes both. It exempts the declaring
  # module — which is what legitimately defines the `ai.rulesDir` L1→L2 reshape,
  # since `ai.rulesDir` is itself a ROOT option with nowhere else to expand to —
  # and needs no maintenance when options move. Consequence to accept: a module
  # that both declares and defines a root option is exempt. Declaring one
  # outside `sharedOptions.nix` would already fail `checks/modules/options-doc.nix`'s
  # cross-backend parity gate, so that is not a quiet path.
  #
  # ── The real cost: reachability ──
  #
  # A definition suppressed by `mkIf false` is DROPPED from the definition list
  # entirely. Measured — it is NOT relabelled to `<unknown-file>`; that entry,
  # when it appears, is the option's default. So this sees only code paths the
  # evaluated config reaches, which the deleted text scan did not depend on.
  #
  # `rootPoolProbeConfig` is therefore load-bearing rather than a convenience:
  # every per-CLI config callback is wrapped in `lib.mkIf cfg.enable`
  # (`lib/ai/app/mkBackendTransform.nix`), so without the runtime enables this
  # guard would evaluate a tree in which the ENTIRE fanout body contributes
  # nothing — the largest and likeliest home for a root write, invisible. The
  # runtimes come from the shared registry so a sixth is covered the day it
  # lands; pool-contributing integrations supply owner-local probes for their own flags.
  #
  # Verified by mutation, not by reading: a root write gated on
  # `config.ai.claude.enable` is reported with these enables and vanishes
  # without them.
  #
  # Second, smaller cost: `definitionsWithLocations` is post-`filterOverrides`,
  # so if some definition wins on PRIORITY (a `mkForce` anywhere) the losing
  # definitions — possibly including a repo root write — drop off the list. That
  # cannot produce the silent-negation bug this guard exists to prevent, since a
  # filtered-out definition contributes nothing to the value either; it only
  # means the reported violation LIST can be incomplete when two definitions of
  # one option disagree on priority.
  #
  # `lib.ai.program` now makes both program levels structural, including both
  # skill packages after row 8. This broader guard remains because a program's
  # implementation callback can still write the wrong pool level, and because
  # non-program package contributors remain valid.
  rootPoolSrcRoot = toString ../..;

  runtimePoolProbeConfig = {
    ai = lib.genAttrs harnessNames (_: {enable = true;});
  };
  withEnabledProgramProbes = probe: lib.recursiveUpdate runtimePoolProbeConfig probe;

  rootPoolProbeConfig = lib.foldl' lib.recursiveUpdate runtimePoolProbeConfig harness.testing.moduleProbes;

  # Isolate each owner probe before combining them so mkForce cannot hide
  # a second package claim. Owners contribute probes in their checks module.
  packagePoolProbeConfigs =
    [runtimePoolProbeConfig rootPoolProbeConfig]
    ++ map withEnabledProgramProbes harness.testing.moduleProbes;

  rootPoolViolations = evaluated: let
    isOurs = file: lib.hasPrefix rootPoolSrcRoot (toString file);
    # `options.ai` holds root options alongside per-runtime GROUPS (ai.claude
    # and friends, ai.internal), which are plain attrsets rather than options.
    # `isOption` selects the root surface, and with NO hardcoded pool list — a
    # pool added to sharedOptions.nix is covered the day it is declared, which
    # the scan's hand-maintained alternation was not.
    #
    # Root groups can nest arbitrarily (`ai.generated.formatter.markdown`).
    # Runtime groups carry enable/files and are excluded with all descendants.
    walk = prefix: group:
      lib.concatLists (lib.mapAttrsToList (name: member: let
        path =
          if prefix == ""
          then name
          else "${prefix}.${name}";
      in
        if lib.isOption member
        then [(lib.nameValuePair path member)]
        else if member ? enable || member ? files
        then []
        else walk path member)
      group);
    rootOptions = walk "" evaluated.options.ai;
    foreignDefs = {
      name,
      value,
    }: let
      declaredIn = map toString (value.declarations or []);
      foreign = d: isOurs d.file && !(lib.elem (toString d.file) declaredIn);
    in
      map (d: "ai.${name} <- ${toString d.file}")
      (lib.filter foreign (value.definitionsWithLocations or []));
  in
    lib.concatMap foreignDefs rootOptions;

  # Throws with the offending option/file pairs rather than a bare "FAIL",
  # because the whole value of this check is telling the next author WHERE. The
  # diagnostic names the module that CONTRIBUTED the definition, which for a
  # factory-produced module is the caller that imported it, not the factory.
  rootPoolClean = backend: evaluated: let
    violations = rootPoolViolations evaluated;
  in
    violations
    == []
    || throw ''
      Root ai.* option defined by a module in this repo (${backend}):

        ${builtins.concatStringsSep "\n  " violations}

      Root options are consumer-owned portable defaults. A package write here
      fans out beyond the package's runtime ownership. Write
      ai.<runtime>.<option> instead, gated on
      `lib.hasAttrByPath ["ai" name "<option>"] options`.
    '';

  # ── Package-vs-package keyed-pool collision guard ───────────────
  # Root and per-runtime scopes are independent: a root entry and a same-key
  # per-runtime entry are the intended replacement boundary. Within either
  # scope, however, two repo packages claiming one key is ambiguous ownership
  # and must fail. Definition provenance distinguishes those package claims
  # from consumer inline config (`<unknown-file>`), while grouping paths under
  # packages/<name>/ prevents two modules of one package from masquerading as
  # two package owners.
  normalizedPoolNames = [
    "agents"
    "environmentVariables"
    "lspServers"
    "mcpServers"
    "rules"
    "skills"
  ];

  packageOwnerOf = file: let
    path = toString file;
    relative = lib.removePrefix "${rootPoolSrcRoot}/" path;
    parts = lib.splitString "/" relative;
  in
    if builtins.length parts >= 2 && builtins.head parts == "packages"
    then builtins.elemAt parts 1
    # Test fixtures live outside packages/; treating each fixture file as an
    # owner keeps the positive control sensitive without inventing fake
    # production packages.
    else path;

  packagePoolClaims = evaluated: let
    isOurs = file: lib.hasPrefix rootPoolSrcRoot (toString file);
    scopes =
      [
        {
          label = "ai";
          path = ["ai"];
        }
      ]
      ++ map (runtime: {
        label = "ai.${runtime}";
        path = ["ai" runtime];
      })
      harnessNames;
    claimsFor = scope: pool: let
      optionPath = scope.path ++ [pool];
      opt = lib.attrByPath optionPath null evaluated.options;
      declaredIn = map toString (opt.declarations or []);
      isPackageDefinition = definition:
        isOurs definition.file
        && !(lib.elem (toString definition.file) declaredIn)
        && builtins.isAttrs definition.value;
      definitions =
        if opt == null || !(lib.isOption opt)
        then []
        else lib.filter isPackageDefinition (opt.definitionsWithLocations or []);
      claims = lib.concatMap (definition:
        map (key: {
          file = toString definition.file;
          inherit key;
          owner = packageOwnerOf definition.file;
          id = "${scope.label}.${pool}.${key}";
        }) (builtins.attrNames definition.value))
      definitions;
    in
      claims;
  in
    lib.concatMap (scope:
      lib.concatMap (pool: claimsFor scope pool) normalizedPoolNames)
    scopes;

  packagePoolCollisions = evaluatedOrList: let
    evaluations =
      if builtins.isList evaluatedOrList
      then evaluatedOrList
      else [evaluatedOrList];
    claims = lib.concatMap packagePoolClaims evaluations;
    ids = lib.unique (map (claim: claim.id) claims);
    collisionFor = id: let
      keyClaims = lib.filter (claim: claim.id == id) claims;
      owners = lib.unique (map (claim: claim.owner) keyClaims);
      files = lib.unique (map (claim: claim.file) keyClaims);
    in
      lib.optional (builtins.length owners > 1)
      "${id} <- ${lib.concatStringsSep ", " files}";
  in
    lib.concatMap collisionFor ids;

  packagePoolsClean = backend: evaluatedOrList: let
    collisions = packagePoolCollisions evaluatedOrList;
  in
    collisions
    == []
    || throw ''
      Normalized ai.* pool keys claimed by multiple packages (${backend}):

        ${builtins.concatStringsSep "\n  " collisions}

      Each key has one package owner within a root or per-runtime pool. Root
      and per-runtime scopes remain independent so runtime replacement and
      null negation can operate normally.
    '';
in {
  inherit normalizedPoolNames packageOwnerOf packagePoolClaims packagePoolCollisions packagePoolProbeConfigs packagePoolsClean rootPoolClean rootPoolProbeConfig rootPoolSrcRoot rootPoolViolations runtimePoolProbeConfig withEnabledProgramProbes;
}
