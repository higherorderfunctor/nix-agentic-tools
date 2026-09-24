# One reconciler, two containers, plans as data.
#
# `own` lowers an ordered list of TARGETS into one backend entry point. A
# target names a container (`codec`), where that container lives relative to
# the backend root (`path`), the ledger recording what the last run owned
# (`ledger`, relative to the state root) and the units this generation
# declares. Everything a caller can vary — content, modes, ledger names — is
# data inside one store-resident JSON plan, so there is no name-safety regex,
# no heredoc marker and no quoting class of bug to defend against: the emitted
# body is a strict subshell around a single command whose only arguments are
# store paths.
#
# The HM two-phase split is home-manager's lifecycle, not ours. A rung-2 real
# file flipping to a rung-1 symlink must be GONE before `checkLinkTargets` or
# activation aborts, and a new real file may only appear AFTER
# `linkGeneration`. A document is different: its retraction and its assertion
# are one read-modify-write that must not be split across two processes, so a
# document-only bundle emits the write entry alone.
#
# The result is `{config, plan}`, not a bare module fragment. `config` is what
# the backend gets; `plan` is the same data the store file carries, kept
# eval-visible because the store file cannot be read back — importing a
# derivation is forbidden here, and discarding the plan's string context to
# make it readable would drop the store references that keep a rendered
# command alive in the generation's closure. Module-eval checks read the
# render script, the unit modes and the ledger names out of `plan`, which is
# the SAME value the program executes rather than a mirror of it.
{lib}: let
  inherit (import ./ai-common.nix {inherit lib;}) scopedActivation;

  program = ./own.py;
  codecs = ["dir" "json" "toml"];
  contentFields = ["run" "store" "text"];

  backends = {
    devenv = {
      root = "$DEVENV_ROOT";
      state = "$DEVENV_STATE/nix-agentic-tools";
    };
    hm = {
      root = "$HOME";
      state = "\${XDG_STATE_HOME:-$HOME/.local/state}/nix-agentic-tools";
    };
  };

  traverses = value: let
    parts = lib.splitString "/" value;
  in
    value == "" || lib.hasPrefix "/" value || builtins.any (part: part == "" || part == "." || part == "..") parts;

  # `content` is a tagged sum — `{ text }`, `{ store }` or `{ run }` — which is
  # what collapses the old text/source/renderCommand/settingsJson quartet and
  # its XOR assertion. The shape is still checked, because a record with two
  # tags or a typo'd tag is a caller error a silent winner would hide.
  contentErrors = label: record: let
    present = builtins.filter (field: record ? ${field}) contentFields;
    extra = builtins.filter (field: !builtins.elem field (contentFields ++ ["mode"])) (builtins.attrNames record);
  in
    lib.optional (builtins.length present != 1)
    "${label} must set exactly one of ${lib.concatStringsSep "/" contentFields}"
    ++ lib.optional (extra != [])
    "${label} has unknown field(s) ${lib.concatStringsSep ", " extra}";

  targetErrors = target: let
    label = "target '${target.path or "<unnamed>"}'";
    missing = builtins.filter (field: !(target ? ${field})) ["codec" "ledger" "path" "units"];
    extra = builtins.filter (field: !builtins.elem field ["codec" "ledger" "lock" "path" "units"]) (builtins.attrNames target);
  in
    if missing != [] || extra != []
    then
      lib.optional (missing != []) "${label} is missing ${lib.concatStringsSep ", " missing}"
      ++ lib.optional (extra != []) "${label} has unknown field(s) ${lib.concatStringsSep ", " extra}"
    else
      lib.optional (!builtins.elem target.codec codecs)
      "${label} has unknown codec '${toString target.codec}' (expected ${lib.concatStringsSep "/" codecs})"
      ++ lib.optional (traverses target.path) "${label} path must be relative and must not traverse"
      ++ lib.optional (traverses target.ledger) "${label} ledger '${target.ledger}' must be relative and must not traverse"
      # A native writer's lock guards one document's read-modify-write; a
      # directory's units are published one atomic file at a time.
      ++ lib.optional (target ? lock && target.codec == "dir") "${label} lock is for document targets only"
      ++ lib.optional (target ? lock && (!builtins.isString target.lock || traverses target.lock)) "${label} lock must be relative and must not traverse"
      ++ (
        if target.codec == "dir"
        then
          lib.concatMap (address:
            # A unit address is still a path segment, so it must not traverse.
            # A dot-prefixed one is barred for a second reason: the TSV ledger
            # reader REFUSES a dot-prefixed entry rather than deleting it, so
            # such a unit could be written and never retracted, and the
            # reserved `.nat-tmp.` sweep namespace lives in the same space.
              lib.optional (address == "" || lib.hasInfix "/" address || lib.hasPrefix "." address)
              "${label} unit address '${address}' must be one visible path segment"
              ++ lib.optional (target.units.${address} ? mode && builtins.match "0?[0-7]{3}" target.units.${address}.mode == null)
              "${label} unit '${address}' mode must be octal permissions, not '${toString target.units.${address}.mode}'"
              ++ contentErrors "${label} unit '${address}'" target.units.${address})
          (builtins.attrNames target.units)
        else if target.units == {}
        then []
        else
          # A leaf has no mode of its own — every leaf of a document lives in
          # the same file — so the mode a document target may state is the
          # FILE's, and it is optional. Absent, an existing regular file keeps
          # the mode it has and a new one gets 0600. Stated, it is imposed on
          # every write and on the run where the bytes did not move; kiro's
          # merge target states it so a file an overwrite generation published
          # 0444 goes back to being hand-editable, and so a substituted
          # credential url never sits in a group-readable file.
          lib.optional (target.units ? mode && builtins.match "0?[0-7]{3}" target.units.mode == null)
          "${label} declaration mode must be octal permissions, not '${toString target.units.mode}'"
          ++ contentErrors "${label} declaration" (builtins.removeAttrs target.units ["mode"])
      );

  # The values that occur more than once, which is the only thing either
  # uniqueness rule below has to say.
  repeated = values: lib.unique (builtins.filter (value: builtins.length (builtins.filter (other: other == value) values) > 1) values);

  bundleErrors = {
    backend,
    entryNames,
    hasDirectory,
    targets,
  }: let
    ledgers = map (target: target.ledger or "") targets;
    # LIVE targets only. A target declaring nothing does not claim its path —
    # it RELEASES it, which is what makes the overwrite/merge handover one
    # ordinary reconcile. Two live targets on one path is the opposite: each
    # publishes over the other's bytes, and the second one to run adopts the
    # first one's file as an unmanaged hand edit, backing it up once per
    # generation forever.
    livePaths = map (target: target.path) (builtins.filter (target: target ? path && (target.units or {}) != {}) targets);
    sharedLedgers = repeated ledgers;
    sharedPaths = repeated livePaths;
  in
    lib.optional (!builtins.elem backend (builtins.attrNames backends))
    "unknown backend '${toString backend}' (expected ${lib.concatStringsSep "/" (builtins.attrNames backends)})"
    ++ lib.optional (targets == []) "a bundle must declare at least one target"
    ++ lib.optional (sharedLedgers != [])
    "two targets share a ledger: ${lib.concatStringsSep ", " sharedLedgers}"
    ++ lib.optional (sharedPaths != [])
    "two live targets claim the path: ${lib.concatStringsSep ", " sharedPaths}"
    ++ lib.optional (!(entryNames ? write)) "entryNames.write is required"
    ++ lib.optional (backend == "hm" && hasDirectory && !(entryNames ? prune))
    "entryNames.prune is required: a directory target needs the prune entry that runs before checkLinkTargets";

  # The exports are the reason the subshell is mandatory rather than tidy:
  # home-manager concatenates every activation entry into one script, and
  # NAT_OWN_* must not outlive this one. Nothing here ever runs `exit` — a
  # failing python invocation exits the subshell non-zero, which the caller's
  # `set -e` sees, while `exit` would truncate the whole concatenated script.
  body = {
    backend,
    plan,
    python,
  }: arguments: ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    export NAT_OWN_ROOT="${backends.${backend}.root}"
    export NAT_OWN_STATE="${backends.${backend}.state}"
    ${python}/bin/python3 ${lib.escapeShellArg "${program}"} --plan ${lib.escapeShellArg "${plan}"} ${arguments}
  '';
in
  {
    backend,
    entryNames,
    targets,
    after ? [],
    hasFiles ? false,
    python,
    pkgs,
  }: let
    hasDirectory = builtins.any (target: (target.codec or null) == "dir") targets;
    errors = bundleErrors {inherit backend entryNames hasDirectory targets;} ++ lib.concatMap targetErrors targets;
    checked =
      if errors == []
      then targets
      else throw "ai.own: ${lib.concatStringsSep "; " errors}";
    # `bash` is in the plan rather than in the environment for the same reason
    # everything else is: the runtime interface stays two env vars, and a
    # renderer runs the interpreter this closure pins instead of whatever an
    # activation's PATH happens to resolve.
    plan = {
      bash = "${pkgs.bash}/bin/bash";
      targets = checked;
    };
    invoke = body {
      inherit backend python;
      plan = pkgs.writeText "nat-own-plan.json" (builtins.toJSON plan);
    };
  in
    # Force the validation before anything else in the result. Without this an
    # unknown backend or a missing entry name surfaces as nix's own
    # attribute-missing error, which names neither the target nor the fix.
    builtins.seq checked {
      inherit plan;
      config =
        if backend == "hm"
        then {
          home.activation =
            {
              ${entryNames.write} =
                lib.hm.dag.entryAfter (["linkGeneration"] ++ after)
                (scopedActivation (invoke "--phase all"));
            }
            // lib.optionalAttrs hasDirectory {
              ${entryNames.prune} =
                lib.hm.dag.entryBefore ["checkLinkTargets"]
                (scopedActivation (invoke "--phase prune"));
            };
        }
        else {
          # A failed writer only warns at shell entry; this is what makes
          # `devenv test` and CI fail. enterTest is a test script rather than
          # an activation entry, so it exits explicitly — a non-zero command
          # there does not necessarily abort the run.
          enterTest = ''
            if ! (
            ${invoke "--verify"}
            ); then
              exit 1
            fi
          '';
          tasks.${entryNames.write} = {
            after = ["devenv:files:cleanup"] ++ after;
            # The `devenv:files` edge MUST stay conditional:
            # `tasks."devenv:files"` exists only when `config.files != {}` and
            # the runner hard-errors on a dangling ref. The unconditional
            # `devenv:enterShell` edge alone then guarantees write-before-shell.
            before = ["devenv:enterShell"] ++ lib.optional hasFiles "devenv:files";
            exec = scopedActivation (invoke "--phase all");
          };
        };
    }
