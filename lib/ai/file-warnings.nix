# Observe the final devenv sinks after its files tasks. The private ledger keeps
# retired AI paths visible even after upstream overwrites files.json; it never
# grants deletion ownership and survives a runtime being disabled.
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
  roots = builtins.listToAttrs (lib.concatMap (runtime: let
    cfg = ai.${runtime} or {};
  in
    lib.optionals (cfg.enable or false) (map (name: {
        inherit name;
        value = "ai.${runtime}.files (including generated ai.${runtime} configuration)";
      })
      ([
          (
            if runtime == "codex"
            then ".codex"
            else cfg.configDir or ".${runtime}"
          )
        ]
        ++ lib.optional (runtime == "codex") ".agents/skills"
        ++ lib.optionals (runtime == "copilot") (map (suffix: "${cfg.projectDir or ".github"}/${suffix}") ["agents" "copilot-instructions.md" "instructions" "skills"])
        ++ lib.optional (runtime == "claude") ".mcp.json"
        ++ lib.optional (builtins.elem runtime ["codex" "kiro"]) (cfg.context.filename or "AGENTS.md"))))
  runtimes);
  fileSpecs = lib.concatMap (runtime: let
    cfg = ai.${runtime} or {};
    # Codex configDir is HOME-relative; its project discovery path is fixed.
    prefix =
      if runtime == "codex"
      then ".codex"
      else cfg.configDir or ".${runtime}";
    projectPrefix = cfg.projectDir or ".github";
    matches = name:
      builtins.hasAttr name (cfg.files or {})
      || lib.hasPrefix "${prefix}/" name
      || (runtime == "codex" && lib.hasPrefix ".agents/skills/" name)
      || (runtime == "copilot" && lib.hasPrefix "${projectPrefix}/" name)
      || (builtins.elem runtime ["codex" "kiro"] && builtins.hasAttr name config.ai.internal.files)
      || (runtime == "claude" && name == ".mcp.json");
    origins = name: let
      rows = lib.filter (row:
        row.ecosystem
        == runtime
        && row.mode == "devenv"
        && row.target != null
        && lib.hasPrefix "$DEVENV_ROOT/" row.target)
      policy.rows;
      # Policy templates use default directories. Rebase those prefixes onto
      # the evaluated paths so a custom configDir keeps its source option.
      related = lib.filter (row: let
        defaultPrefix = options.ai.${runtime}.configDir.default or ".${runtime}";
        defaultProjectPrefix = options.ai.${runtime}.projectDir.default or ".github";
        original = lib.removePrefix "$DEVENV_ROOT/" row.target;
        target =
          if lib.hasPrefix "${defaultPrefix}/" original
          then prefix + lib.removePrefix defaultPrefix original
          else if runtime == "copilot" && lib.hasPrefix "${defaultProjectPrefix}/" original
          then projectPrefix + lib.removePrefix defaultProjectPrefix original
          else if original == "AGENTS.md"
          then cfg.context.filename or original
          else original;
        stem = builtins.head (lib.splitString "<" target);
      in
        name == target || (lib.hasInfix "<" target && lib.hasPrefix stem name))
      rows;
    in
      lib.concatStringsSep ", " (lib.unique (map lib.showOption (lib.concatMap (row: row.inputOptions) related))
        ++ ["ai.${runtime}.files.${builtins.toJSON name}"]);
  in
    lib.optionals (cfg.enable or false) (lib.mapAttrsToList (name: file: {
      inherit name;
      value = {
        mode = file.copyMode or "symlink";
        option = origins name;
        source = file.file or file.source or null;
      };
    }) (lib.filterAttrs (name: _: matches name) config.files)))
  runtimes;
  desired = builtins.listToAttrs fileSpecs;
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
          ${pkgs.writeText "ai-delivery-roots.json" (builtins.toJSON roots)}
      '';
    };
    # Emitted as a VALUE-level conditional, never a structural one: deciding
    # whether to DEFINE config by reading `config.files` forces it while
    # `_module.freeformType` is still being evaluated, which is an infinite
    # recursion. A project with no ai.* runtime declared gets the empty string,
    # so `enterShell == ""` still holds for a consumer that never opted in.
    #
    # Residual, accepted: `roots` is built from `cfg.enable`, so disabling the
    # last runtime also stops the shell-entry REPORT. The ledger task below is
    # unconditional and keeps recording, so nothing is lost — it is surfaced
    # again as soon as any runtime is enabled.
    enterShell = lib.optionalString (roots != {}) ''
      ${pkgs.python3}/bin/python ${./file-warnings.py} \
        ${lib.escapeShellArg config.devenv.root} \
        ${lib.escapeShellArg config.devenv.state} \
        ${pkgs.writeText "ai-delivery-files.json" (builtins.toJSON desired)} \
        ${pkgs.writeText "ai-delivery-current-files.json" (builtins.toJSON (builtins.attrNames config.files))}
      ${lib.optionalString ((ai.kiro.enable or false) && builtins.elem "workflows" (ai.kiro.unlockedRolloutFeatures or [])) ''
        ${pkgs.python3}/bin/python ${./file-warnings.py} workflows "''${KIRO_HOME:-$HOME/.kiro}"
      ''}
    '';
  };
}
