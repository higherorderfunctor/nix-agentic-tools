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
    extra = builtins.filter (field: !builtins.elem field ["codec" "ledger" "path" "units"]) (builtins.attrNames target);
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
          # A container whose units are leaves of a shared byte stream has no
          # business restating the document's mode; it preserves an existing
          # file's and uses 0600 for a new one. Fail rather than ignore.
          lib.optional (target.units ? mode)
          "${label} declares a mode, which a document container never imposes"
          ++ contentErrors "${label} declaration" (builtins.removeAttrs target.units ["mode"])
      );

  bundleErrors = {
    backend,
    entryNames,
    hasDirectory,
    targets,
  }: let
    ledgers = map (target: target.ledger or "") targets;
  in
    lib.optional (!builtins.elem backend (builtins.attrNames backends))
    "unknown backend '${toString backend}' (expected ${lib.concatStringsSep "/" (builtins.attrNames backends)})"
    ++ lib.optional (targets == []) "a bundle must declare at least one target"
    ++ lib.optional (lib.unique ledgers != ledgers)
    "two targets share a ledger: ${lib.concatStringsSep ", " (lib.unique (builtins.filter (name: builtins.length (builtins.filter (other: other == name) ledgers) > 1) ledgers))}"
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
    plan = pkgs.writeText "nat-own-plan.json" (builtins.toJSON {targets = checked;});
    invoke = body {inherit backend plan python;};
  in
    # Force the validation before anything else in the result. Without this an
    # unknown backend or a missing entry name surfaces as nix's own
    # attribute-missing error, which names neither the target nor the fix.
    builtins.seq checked (
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
        # A failed writer only warns at shell entry; this is what makes `devenv
        # test` and CI fail. enterTest is a test script rather than an
        # activation entry, so it exits explicitly — a non-zero command there
        # does not necessarily abort the run.
        enterTest = ''
          if ! (
          ${invoke "--verify"}
          ); then
            exit 1
          fi
        '';
        tasks.${entryNames.write} = {
          after = ["devenv:files:cleanup"] ++ after;
          # The `devenv:files` edge MUST stay conditional: `tasks."devenv:files"`
          # exists only when `config.files != {}` and the runner hard-errors on a
          # dangling ref. The unconditional `devenv:enterShell` edge alone then
          # guarantees write-before-shell.
          before = ["devenv:enterShell"] ++ lib.optional hasFiles "devenv:files";
          exec = scopedActivation (invoke "--phase all");
        };
      }
    )
