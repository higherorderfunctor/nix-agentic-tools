# Repository validation policy. Each hook is declared once with its local,
# Stop-hook, and CI lifecycles; consumers project only the surface they run.
{
  lib,
  pkgs,
}: let
  shellStrict = import ./shell-strict.nix;

  rejectDefaultBranchCommit = pkgs.writeShellApplication {
    name = "reject-default-branch-commit";
    extraShellCheckFlags = shellStrict.shellcheckFlags;
    inherit (shellStrict) bashOptions;
    text = ''
      ${shellStrict.shoptHeader}
      # Resolve no remote state here: a commit guard must work offline and in
      # a newly created clone. If the protected trunk is renamed, this is the
      # single declaration to update.
      default_branch="main"
      current_branch="$(${pkgs.git}/bin/git rev-parse --abbrev-ref HEAD)"
      if [ "$current_branch" = "$default_branch" ]; then
        printf '%s\n' \
          "error: refusing to commit directly on the default branch ('$default_branch')." \
          "This repo is trunk-based — branch into a worktree first, e.g.:" \
          "  worktrees=\"\$(dirname \"\$(git rev-parse --path-format=absolute --git-common-dir)\")-worktrees\"" \
          "  git worktree add -b <type>/<slug> \"\$worktrees/<slug>\" origin/$default_branch" \
          "(--no-verify bypasses this guard by design.)" >&2
        exit 1
      fi
    '';
  };

  treefmtRestage = pkgs.writeShellApplication {
    name = "treefmt-restage";
    extraShellCheckFlags = shellStrict.shellcheckFlags;
    inherit (shellStrict) bashOptions;
    text = ''
      ${shellStrict.shoptHeader}
      ${pkgs.git}/bin/git diff --name-only -z \
        | ${pkgs.findutils}/bin/xargs -0 -r ${pkgs.git}/bin/git add --
    '';
  };

  # `ci = null` is an explicit local-only decision, not an omitted field.
  # External CI backends name an existing independently shaped gate; derived
  # backends below are generated directly from this table.
  definitions = {
    convco = {
      role = "commit-message";
      hook.enable = true;
      stop = null;
      ci = null;
    };
    cspell = {
      role = "validator";
      hook = {
        enable = true;
        excludes = [
          ".*-package-lock\\.json$"
          ".*\\.lock$"
          "^config/cspell/"
          "^docs/"
          # Verbatim engine-bundle quotes and real command output, including
          # identifier fragments cut mid-token by windowed byte extraction.
          "^fixtures/kiro-primitives/evidence/"
          "^fixtures/kiro-primitives/records/"
          "^overlays/chatgpt-codex-extracted\\.json$"
          "^overlays/claude-code-extracted\\.json$"
          # Patch files are verbatim third-party code plus Git blob hashes.
          ".*\\.patch$"
        ];
      };
      stop = "judgment";
      ci.backend = "git-hooks";
    };
    deadnix = {
      role = "validator";
      hook = {
        enable = true;
        excludes = ["overlays/sources/.*"];
      };
      stop = "judgment";
      ci.backend = "git-hooks";
    };
    gitleaks = {
      role = "security";
      hook = {
        enable = true;
        name = "gitleaks";
        entry = "${pkgs.gitleaks}/bin/gitleaks protect --staged --verbose --redact";
        pass_filenames = false;
        stages = ["pre-commit"];
      };
      stop = null;
      ci = {
        backend = "external";
        check = "gitleaks";
      };
    };
    reject-default-branch-commit = {
      role = "commit-guard";
      hook = {
        enable = true;
        name = "reject-default-branch-commit";
        entry = lib.getExe rejectDefaultBranchCommit;
        pass_filenames = false;
        always_run = true;
        stages = ["pre-commit"];
      };
      stop = null;
      ci = null;
    };
    shellcheck = {
      role = "validator";
      hook = {
        enable = true;
        args = ["-x"] ++ shellStrict.shellcheckFlags;
      };
      stop = "judgment";
      # The dedicated backend deliberately scans extensionless/shebang shell
      # files too and hard-fails an empty corpus.
      ci.backend = "shellcheck-corpus";
    };
    statix = {
      role = "validator";
      hook = {
        enable = true;
        excludes = ["overlays/sources/.*"];
      };
      stop = "judgment";
      ci.backend = "git-hooks";
    };
    treefmt = {
      role = "formatter";
      hook = {
        enable = true;
        require_serial = true;
        settings.no-cache = false;
      };
      stop = "formatter";
      ci = {
        backend = "external";
        check = "formatting";
      };
    };
    treefmt-restage = {
      role = "commit-helper";
      hook = {
        enable = true;
        name = "treefmt-restage";
        entry = lib.getExe treefmtRestage;
        pass_filenames = false;
        stages = ["pre-commit"];
      };
      stop = null;
      ci = null;
    };
  };

  definitionNames = builtins.attrNames definitions;
  validRoles = [
    "commit-guard"
    "commit-helper"
    "commit-message"
    "formatter"
    "security"
    "validator"
  ];
  validCiBackends = [
    "external"
    "git-hooks"
    "shellcheck-corpus"
  ];
  validStopValues = [
    null
    "formatter"
    "judgment"
  ];
  ciRequiredRoles = [
    "formatter"
    "security"
    "validator"
  ];
  fieldsComplete = lib.all (definition:
    definition ? role
    && definition ? hook
    && definition ? stop
    && definition ? ci)
  (builtins.attrValues definitions);
  rolesValid = lib.all (definition: builtins.elem definition.role validRoles) (builtins.attrValues definitions);
  stopValuesValid = lib.all (definition: builtins.elem definition.stop validStopValues) (builtins.attrValues definitions);
  ciShapesValid = lib.all (definition:
    definition.ci
    == null
    || (builtins.isAttrs definition.ci
      && definition.ci ? backend
      && builtins.elem definition.ci.backend validCiBackends
      && (definition.ci.backend != "external" || definition.ci ? check)))
  (builtins.attrValues definitions);
  ciCoverageComplete = lib.all (definition:
    builtins.elem definition.role ciRequiredRoles
    == (definition.ci != null))
  (builtins.attrValues definitions);
  stopCoverageComplete = lib.all (definition:
    (definition.role != "validator" || definition.stop == "judgment")
    && (definition.role != "formatter" || definition.stop == "formatter"))
  (builtins.attrValues definitions);

  # Any Stop participant also receives a manual stage. This is the stage used
  # by both the Stop hook and devenv's diagnostic run, so commit-only lifecycle
  # hooks can never leak into either surface.
  localHooks = lib.mapAttrs (_: definition:
    definition.hook
    // lib.optionalAttrs (definition.stop != null) {
      stages = lib.unique ((definition.hook.stages or ["pre-commit"]) ++ ["manual"]);
    })
  definitions;

  selectNames = predicate:
    builtins.attrNames (lib.filterAttrs (_: predicate) definitions);
  judgmentHookIds = selectNames (definition: definition.stop == "judgment");
  formatterHookIds = selectNames (definition: definition.stop == "formatter");
  gitHooksCiIds = selectNames (definition: (definition.ci or null) != null && definition.ci.backend == "git-hooks");
  shellcheckCorpusIds = selectNames (definition: (definition.ci or null) != null && definition.ci.backend == "shellcheck-corpus");

  ciHooks = lib.genAttrs gitHooksCiIds (name:
    localHooks.${name}
    // {
      # git-hooks.nix recognizes an all-manual configuration and invokes prek
      # with the matching stage, instead of its unscoped default.
      stages = ["manual"];
    });
in
  assert lib.assertMsg fieldsComplete "every repo-validation hook must declare role, hook, stop, and ci";
  assert lib.assertMsg rolesValid "repo-validation contains an unsupported role";
  assert lib.assertMsg stopValuesValid "repo-validation contains an unsupported Stop lifecycle";
  assert lib.assertMsg ciShapesValid "repo-validation contains an invalid CI declaration";
  assert lib.assertMsg ciCoverageComplete "every validator, formatter, and security hook must have CI coverage; commit lifecycle hooks must remain local";
  assert lib.assertMsg stopCoverageComplete "every validator must be Stop judgment feedback and every formatter must be the Stop formatter";
  assert lib.assertMsg (formatterHookIds == ["treefmt"]) "repo-validation must declare exactly one Stop formatter";
  assert lib.assertMsg (shellcheckCorpusIds == ["shellcheck"]) "the corpus backend currently supports exactly shellcheck";
  assert lib.assertMsg (lib.all (name: definitions.${name}.role == "validator") (judgmentHookIds ++ gitHooksCiIds ++ shellcheckCorpusIds)) "only validators may enter derived judgment or CI lint surfaces";
  assert lib.assertMsg (lib.all (name: builtins.elem "manual" localHooks.${name}.stages) (judgmentHookIds ++ formatterHookIds)) "every Stop hook must support the manual stage"; {
    inherit definitionNames definitions formatterHookIds judgmentHookIds localHooks;
    formatterHookId = builtins.head formatterHookIds;

    mkCiChecks = {
      gitHooksRun,
      src,
    }: let
      localProjection = gitHooksRun {
        inherit src;
        hooks = localHooks;
        package = pkgs.prek;
      };
      repoLints = gitHooksRun {
        inherit src;
        hooks = ciHooks;
        package = pkgs.prek;
      };
    in {
      repo-lints = repoLints;
      repo-validation-policy = import ../checks/repo-validation-policy.nix {
        inherit definitionNames formatterHookIds judgmentHookIds pkgs;
        ciConfig = repoLints.config.configFile;
        ciHookIds = gitHooksCiIds;
        localConfig = localProjection.config.configFile;
        rejectEntry = definitions.reject-default-branch-commit.hook.entry;
      };
      shellcheck-corpus = import ../checks/shellcheck-corpus.nix {inherit lib pkgs;};
    };
  }
