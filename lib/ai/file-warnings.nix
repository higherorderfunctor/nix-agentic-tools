# Observe the final devenv sinks after its files tasks. The private ledger keeps
# retired AI paths visible even after upstream overwrites files.json; it never
# grants deletion ownership and survives a runtime being disabled.
#
# Provenance is EXACT, never a config-directory prefix. `.codex/` and `.github/`
# are shared namespaces: a consumer may declare `files.".codex/notes.md"` of
# their own, and classifying it by prefix made this module report a retention
# warning naming an `ai.*` option that never wrote the file. The managed set is
# therefore the runtime's own file registry and the literal targets the
# delivery policy declares — plus, for the templated `<name>` targets, only the
# directory stem the policy itself claims.
#
# The shared AGENTS.md owner (`ai.internal.files`) is not read here. Each
# runtime's own key already arrives through its policy `AGENTS.md` writer,
# rebased onto the key its factory declares in `ai.internal.agentsMdTargets`,
# and a public override on it is already in the runtime's `files`. The key is
# read from the factory, not from `context.filename`: Kimchi's names its Home
# Manager harness file while its devenv factory always writes AGENTS.md.
# Reading the whole owner per runtime attributed every runtime's key to the
# first one listed, so Kiro's context file was reported as `ai.codex.files`.
#
# Several runtimes can still write one path: Codex, Kimchi and Kiro all default
# to the project-root AGENTS.md, and Codex publishes its key even with no
# content. Each path therefore names every writer's options, folded across
# runtimes. A first-wins map named only `ai.codex.*` for Kimchi's text.
{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  isDevenv = lib.hasAttrByPath ["devenv" "state"] options && options ? files && options ? enterShell;
  policy = import ../../config/ai-delivery.nix {inherit lib;};
  runtimes = import ./runtimes.nix;
  inherit (config) ai;
  # Every devenv writer the policy declares for this runtime, with the policy's
  # default directories rebased onto the evaluated ones so a custom configDir
  # keeps its source option. additionalWriters count: a second document under
  # the same row (Kimchi's harness/settings.json) is a managed path too.
  policyTargets = runtime: let
    cfg = ai.${runtime} or {};
    # Codex configDir is HOME-relative; its project discovery path is fixed.
    prefix =
      if runtime == "codex"
      then ".codex"
      else cfg.configDir or ".${runtime}";
    projectPrefix = cfg.projectDir or ".github";
    defaultPrefix = options.ai.${runtime}.configDir.default or ".${runtime}";
    defaultProjectPrefix = options.ai.${runtime}.projectDir.default or ".github";
    rebase = original:
      if lib.hasPrefix "${defaultPrefix}/" original
      then prefix + lib.removePrefix defaultPrefix original
      else if runtime == "copilot" && lib.hasPrefix "${defaultProjectPrefix}/" original
      then projectPrefix + lib.removePrefix defaultProjectPrefix original
      else if original == "AGENTS.md"
      then ai.internal.agentsMdTargets.${runtime} or original
      else original;
  in
    map (writer: {
      # additionalWriters carry their own inputs or none; only primary rows are
      # stamped with the surface's shared list.
      inputOptions = writer.inputOptions or [];
      target = rebase (lib.removePrefix "$DEVENV_ROOT/" writer.target);
    })
    (lib.filter (writer:
      writer.ecosystem
      == runtime
      && writer.mode == "devenv"
      && writer.target != null
      && lib.hasPrefix "$DEVENV_ROOT/" writer.target)
    (lib.concatMap policy.writersOf policy.rows));
  ownedFor = runtime: let
    cfg = ai.${runtime} or {};
    targets = policyTargets runtime;
    templated = entry: lib.hasInfix "<" entry.target;
    # A `<name>` / `<leaf>` template names a directory the policy claims for
    # generated per-entry artifacts, so its stem matches as a prefix. A whole
    # config directory never does.
    matching = name:
      lib.filter (entry:
        entry.target
        == name
        || (templated entry
          && lib.hasPrefix (builtins.head (lib.splitString "<" entry.target)) name))
      targets;
    options = name:
      map lib.showOption (lib.concatMap (entry: entry.inputOptions) (matching name))
      ++ ["ai.${runtime}.files.${builtins.toJSON name}"];
    names =
      builtins.attrNames (cfg.files or {})
      ++ map (entry: entry.target) (lib.filter (entry: !(templated entry)) targets);
  in
    lib.optionalAttrs (cfg.enable or false) (lib.genAttrs (lib.unique names) options);
  # Name -> the consumer options that write it. Shared with the snapshot task,
  # so the ledger bootstrap and the delivery report agree on what is managed.
  owned =
    lib.mapAttrs (_: lists: lib.concatStringsSep ", " (lib.unique (lib.concatLists lists)))
    (lib.zipAttrs (map ownedFor runtimes));
  # Paths an owned writer delivers this generation. A copy or a reconciled
  # document never appears in `config.files`, so without these a path that
  # moved from a store symlink to an owned copy (the shared AGENTS.md, say)
  # would read as removed-but-retained on every shell entry.
  ownedPaths = lib.concatMap (plans:
    lib.concatMap (record:
      lib.concatMap (target:
        if target.codec == "dir"
        then
          map (address:
            if target.path == "."
            then address
            else "${target.path}/${address}")
          (builtins.attrNames target.units)
        else lib.optional (target.units != {}) target.path)
      record.plan.targets)
    (builtins.attrValues plans))
  (map (runtime: ai.${runtime}._ownPlans or {}) (runtimes ++ ["internal"]));
  desired =
    lib.mapAttrs (name: file: {
      mode = file.copyMode or "symlink";
      option = owned.${name};
      source = file.file or file.source or null;
    })
    (lib.filterAttrs (name: _: builtins.hasAttr name owned) config.files);
in {
  config = lib.optionalAttrs isDevenv {
    tasks."ai:delivery:observe-retired" = {
      description = "Remember retired AI file declarations before devenv cleanup";
      before = ["devenv:files:cleanup"];
      exec = ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${pkgs.python3}/bin/python ${./file-warnings.py} snapshot \
          ${lib.escapeShellArg config.devenv.state} \
          ${pkgs.writeText "ai-delivery-owned.json" (builtins.toJSON owned)}
      '';
    };
    # Emitted as a VALUE-level conditional, never a structural one: deciding
    # whether to DEFINE config by reading `config.files` forces it while
    # `_module.freeformType` is still being evaluated, which is an infinite
    # recursion. A project with no ai.* runtime declared gets the empty string,
    # so `enterShell == ""` still holds for a consumer that never opted in.
    #
    # Residual, accepted: `owned` is built from `cfg.enable`, so disabling the
    # last runtime also stops the shell-entry REPORT. The ledger task below is
    # unconditional and keeps recording, so nothing is lost — it is surfaced
    # again as soon as any runtime is enabled.
    enterShell = lib.optionalString (owned != {}) ''
      ${pkgs.python3}/bin/python ${./file-warnings.py} \
        ${lib.escapeShellArg config.devenv.root} \
        ${lib.escapeShellArg config.devenv.state} \
        ${pkgs.writeText "ai-delivery-files.json" (builtins.toJSON desired)} \
        ${pkgs.writeText "ai-delivery-current-files.json" (builtins.toJSON (builtins.attrNames config.files ++ ownedPaths))}
      ${lib.optionalString ((ai.kiro.enable or false) && builtins.elem "workflows" (ai.kiro.unlockedRolloutFeatures or [])) ''
        ${pkgs.python3}/bin/python ${./file-warnings.py} workflows "''${KIRO_HOME:-$HOME/.kiro}"
      ''}
    '';
  };
}
