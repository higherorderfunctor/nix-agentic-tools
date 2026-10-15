# One reconciler, two containers, plans as data — a general library, not an
# ai.* one. Its callers are every runtime's file delivery (through `mkBundle`)
# and any other program that owns part of a file it shares with something
# else, such as a service start script that reconciles declared fields into
# files a login wrote.
#
# A plan is an ordered list of TARGETS. A target names a container (`codec`),
# where that container lives relative to the root (`path`), the ledger
# recording what the last run owned (`ledger`, relative to the state root) and
# the units this run declares. Everything a caller can vary — content, modes,
# ledger names — is data inside one store-resident JSON plan, so there is no
# name-safety regex, no heredoc marker and no quoting class of bug to defend
# against: the command is a single program whose plan is a store path, or a
# plan file a caller writes at run time from a validated mkPlan result, which
# the program validates again.
#
# API:
#   mkPlan {pkgs, targets} -> {file, value}: the validated plan.
#   mkCommand {launch ? "", pkgs, plan ? null, planFile ? null, python,
#     root, state} -> arguments -> the one command line that runs a plan
#     against two roots: an mkPlan result, or a plan file written at run time.
#   mkBundle {backend, entryNames, targets, after ? [], hasFiles ? false,
#     pkgs, python} -> {config, plan}: home-manager or devenv entries.
#   program -> ./own.py, for test drivers that run it directly.
#   scopedActivation body -> body in a subshell, so its shell flags end
#     with it (re-exported by lib/ai/ai-common.nix).
#
# The HM two-phase split is home-manager's lifecycle, not ours. A rung-2 real
# file flipping to a rung-1 symlink must be GONE before `checkLinkTargets` or
# activation aborts, and a new real file may only appear AFTER
# `linkGeneration`. A document is different: its retraction and its assertion
# are one read-modify-write that must not be split across two processes, so a
# document-only bundle emits the write entry alone.
#
# `mkBundle` returns `{config, plan}`, not a bare module fragment. `config` is
# what the backend gets; `plan` is the same data the store file carries, kept
# eval-visible because the store file cannot be read back — importing a
# derivation is forbidden here, and discarding the plan's string context to
# make it readable would drop the store references that keep a rendered
# command alive in the generation's closure. Module-eval checks read the
# render script, the unit modes and the ledger names out of `plan`, which is
# the SAME value the program executes rather than a mirror of it.
{lib}: let
  # ── Activation flag scoping ────────────────────────────────────────
  # Wrap a home.activation body in a subshell so its `set`/`shopt` flags
  # cannot outlive it.
  #
  # home-manager concatenates every DAG entry into ONE script that it opens
  # with `set -eu` + `set -o pipefail`. Flags an entry turns on stay on for
  # every LATER entry — including home-manager's own checkLinkTargets,
  # writeBoundary and linkGeneration. `inherit_errexit` is the one that bites:
  # it changes whether a failing `$( )` aborts, so leaking it silently
  # re-specifies the failure semantics of code we do not own.
  #
  # Scoping rather than dropping the flags keeps our own bodies fully strict
  # while making the leak structurally impossible. Safe only for bodies with no
  # parent-shell effects (no export, no cd, no trap) — check before wrapping.
  #
  # Failure still propagates: a body ending in `false` makes the subshell exit
  # non-zero, which the caller's `set -e` sees exactly as before. Use `false`,
  # never `exit` — `exit` would truncate the whole concatenated activation
  # script rather than failing one entry.
  scopedActivation = body: ''
    (
    ${body}
    )
  '';

  program = ./own.py;
  codecs = ["dir" "json"];
  contentFields = ["run" "store" "text"];

  # `launch` prefixes the one mutating command. Home-manager's `run` helper
  # echoes instead of executing when DRY_RUN is set, which is the only thing
  # that keeps `home-manager switch --dry-run` from writing runtime settings
  # and ledgers: own.py itself never reads DRY_RUN. devenv has no dry-run
  # mode and no `run` helper, so its command is launched bare.
  backends = {
    devenv = {
      launch = "";
      root = "$DEVENV_ROOT";
      state = "$DEVENV_STATE/nix-agentic-tools";
    };
    hm = {
      launch = "run ";
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
    extra = builtins.filter (field: !builtins.elem field ["codec" "ledger" "path" "units"]) (builtins.attrNames target);
  in
    if missing != [] || extra != []
    then
      lib.optional (missing != []) "${label} is missing ${lib.concatStringsSep ", " missing}"
      ++ lib.optional (extra != []) "${label} has unknown field(s) ${lib.concatStringsSep ", " extra}"
    else
      lib.optional (!builtins.elem target.codec codecs)
      "${label} has unknown codec '${toString target.codec}' (expected ${lib.concatStringsSep "/" codecs})"
      # A directory container may be the backend root itself (`.`): the
      # repository-root AGENTS.md is one unit of it. Its units are still one
      # visible path segment each, so nothing below the root is reachable.
      ++ lib.optional (traverses target.path && !(target.codec == "dir" && target.path == ".")) "${label} path must be relative and must not traverse"
      ++ lib.optional (traverses target.ledger) "${label} ledger '${target.ledger}' must be relative and must not traverse"
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
          # A document owns leaves in a writable state file, not its mode.
          lib.optional (target.units ? mode) "${label} document target cannot state a mode"
          ++ contentErrors "${label} declaration" (builtins.removeAttrs target.units ["mode"])
      );

  # The values that occur more than once, which is the only thing either
  # uniqueness rule below has to say.
  repeated = values: lib.unique (builtins.filter (value: builtins.length (builtins.filter (other: other == value) values) > 1) values);

  planErrors = targets: let
    ledgers = map (target: target.ledger or "") targets;
    # Two live targets on one path conflict: each
    # publishes over the other's bytes, and the second one to run adopts the
    # first one's file as an unmanaged hand edit, backing it up once per
    # generation forever.
    livePaths = map (target: target.path) (builtins.filter (target: target ? path && (target.units or {}) != {}) targets);
    sharedLedgers = repeated ledgers;
    sharedPaths = repeated livePaths;
  in
    lib.optional (targets == []) "a plan must declare at least one target"
    ++ lib.optional (sharedLedgers != [])
    "two targets share a ledger: ${lib.concatStringsSep ", " sharedLedgers}"
    ++ lib.optional (sharedPaths != [])
    "two live targets claim the path: ${lib.concatStringsSep ", " sharedPaths}"
    ++ lib.concatMap targetErrors targets;

  bundleErrors = {
    backend,
    entryNames,
    hasDirectory,
  }:
    lib.optional (!builtins.elem backend (builtins.attrNames backends))
    "unknown backend '${toString backend}' (expected ${lib.concatStringsSep "/" (builtins.attrNames backends)})"
    ++ lib.optional (!(entryNames ? write)) "entryNames.write is required"
    ++ lib.optional (backend == "hm" && hasDirectory && !(entryNames ? prune))
    "entryNames.prune is required: a directory target needs the prune entry that runs before checkLinkTargets";

  fail = errors: throw "own: ${lib.concatStringsSep "; " errors}";

  # `bash` is in the plan rather than in the environment for the same reason
  # everything else is: the runtime interface stays two env vars, and a
  # renderer runs the interpreter this closure pins instead of whatever the
  # caller's PATH happens to resolve. `value` is forced valid before `file`
  # can be built from it.
  mkPlan = {
    pkgs,
    targets,
  }: let
    errors = planErrors targets;
    value =
      if errors == []
      then {
        bash = "${pkgs.bash}/bin/bash";
        inherit targets;
      }
      else fail errors;
  in {
    inherit value;
    file = pkgs.writeText "nat-own-plan.json" (builtins.toJSON value);
  };

  # The one command line that runs a plan, for any shell that runs it: an
  # activation entry, a devenv task, or a service's start script. `root` and
  # `state` are shell text expanded inside double quotes where the command
  # runs (`$HOME`, a resolved directory variable). They reach the program
  # through `env` rather than `export`, so neither outlives the command, and
  # a start script that goes on to exec something else hands it neither.
  # `launch` prefixes the command, for home-manager's `run`. `arguments` is
  # the rest of the program's argv: empty or `--phase all` to reconcile,
  # `--phase prune` for retractions from directory targets only, `--verify` to
  # assert what a completed run claims. A caller whose targets depend on run
  # time (which files exist, which ledgers a past run left) writes its plan
  # then, from an mkPlan result validated at evaluation, and passes that
  # file's path as `planFile`, shell text like `root` and `state`; the
  # program checks the written plan again.
  mkCommand = {
    launch ? "",
    pkgs,
    plan ? null,
    planFile ? null,
    python,
    root,
    state,
  }: arguments: let
    planArgument =
      if planFile != null
      then "\"${planFile}\""
      else lib.escapeShellArg "${plan.file}";
  in "${launch}${pkgs.coreutils}/bin/env NAT_OWN_ROOT=\"${root}\" NAT_OWN_STATE=\"${state}\" ${python}/bin/python3 ${lib.escapeShellArg "${program}"} --plan ${planArgument} ${arguments}";

  # Nothing here ever runs `exit` — a failing python invocation exits the
  # subshell non-zero, which the caller's `set -e` sees, while `exit` would
  # truncate the whole concatenated script. The strict header is why the
  # subshell is mandatory: home-manager concatenates every activation entry
  # into one script, and these flags must not outlive this one.
  body = command: arguments: ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${command arguments}
  '';

  mkBundle = {
    backend,
    entryNames,
    targets,
    after ? [],
    hasFiles ? false,
    python,
    pkgs,
  }: let
    hasDirectory = builtins.any (target: (target.codec or null) == "dir") targets;
    errors = bundleErrors {inherit backend entryNames hasDirectory;};
    plan = mkPlan {inherit pkgs targets;};
    checked =
      if errors == []
      then plan.value
      else fail errors;
    invoke = body (mkCommand {
      inherit pkgs plan python;
      inherit (backends.${backend}) launch root state;
    });
  in
    # Force the validation before anything else in the result. Without this an
    # unknown backend or a missing entry name surfaces as nix's own
    # attribute-missing error, which names neither the target nor the fix.
    builtins.seq checked {
      plan = checked;
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
    };
in {
  inherit mkBundle mkCommand mkPlan program scopedActivation;
}
