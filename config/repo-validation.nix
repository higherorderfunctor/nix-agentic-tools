# Repository validation policy. Each hook is declared once with its local and
# CI lifecycles; consumers project only the surface they run.
{
  lib,
  pkgs,
}: let
  shellStrict = import ./shell-strict.nix;
  strictShellApplication = import ../lib/strict-shell-application.nix pkgs;

  rejectDefaultBranchCommit = strictShellApplication {
    name = "reject-default-branch-commit";
    text = ''
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

  treefmtRestage = strictShellApplication {
    name = "treefmt-restage";
    text = ''
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
      ci = null;
    };
    cspell = {
      role = "validator";
      hook = {
        enable = true;
        excludes = [
          ".*package-lock\\.json$"
          ".*\\.lock$"
          "^config/cspell/"
          "^docs/"
          # Verbatim engine-bundle quotes and real command output, including
          # identifier fragments cut mid-token by windowed byte extraction.
          "^fixtures/kiro-primitives/evidence/"
          "^fixtures/kiro-primitives/records/"
          "^packages/chatgpt-codex/extracted\\.json$"
          "^packages/claude-code/extracted\\.json$"
          "^packages/kimchi/egress-report\\.json$"
          # Patch files are verbatim third-party code plus Git blob hashes.
          ".*\\.patch$"
        ];
      };
      ci.backend = "git-hooks";
    };
    deadnix = {
      role = "validator";
      hook = {
        enable = true;
      };
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
      ci = {
        backend = "external";
        check = "gitleaks";
      };
    };
    markdown-table-cells = {
      role = "validator";
      hook = {
        enable = true;
        name = "markdown-table-cells";
        entry = lib.getExe (import ../lib/markdown/table-cells.nix {inherit pkgs;}).package;
        files = "\\.md$";
        # Same file set the other markdown scanners walk, for the reason
        # checks/markdown/markdown-scan.nix exists: one exclusion list, not three.
        excludes = ["^docs/plans/kiro-v3-research-raw/"];
        stages = ["pre-commit"];
      };
      ci.backend = "git-hooks";
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
      ci = null;
    };
    shellcheck = {
      role = "validator";
      hook = {
        enable = true;
        args = ["-x"] ++ shellStrict.shellcheckFlags;
      };
      # The dedicated backend deliberately scans extensionless/shebang shell
      # files too and hard-fails an empty corpus.
      ci.backend = "shellcheck-corpus";
    };
    statix = {
      role = "validator";
      hook = {
        enable = true;
      };
      ci.backend = "git-hooks";
    };
    treefmt = {
      role = "formatter";
      hook = {
        enable = true;
        require_serial = true;
        settings.no-cache = false;
      };
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
  ciRequiredRoles = [
    "formatter"
    "security"
    "validator"
  ];
  fieldsComplete = lib.all (definition:
    definition ? role
    && definition ? hook
    && definition ? ci)
  (builtins.attrValues definitions);
  rolesValid = lib.all (definition: builtins.elem definition.role validRoles) (builtins.attrValues definitions);
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
  selectNames = predicate:
    builtins.attrNames (lib.filterAttrs (_: predicate) definitions);
  diagnosticHookIds = selectNames (definition: builtins.elem definition.role ["formatter" "validator"]);

  # The devenv diagnostic runs formatters and validators through prek's manual
  # stage. Commit-only lifecycle hooks must not leak into that surface.
  localHooks = lib.mapAttrs (name: definition:
    definition.hook
    // lib.optionalAttrs (builtins.elem name diagnosticHookIds) {
      stages = lib.unique ((definition.hook.stages or ["pre-commit"]) ++ ["manual"]);
    })
  definitions;

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
  assert lib.assertMsg fieldsComplete "every repo-validation hook must declare role, hook, and ci";
  assert lib.assertMsg rolesValid "repo-validation contains an unsupported role";
  assert lib.assertMsg ciShapesValid "repo-validation contains an invalid CI declaration";
  assert lib.assertMsg ciCoverageComplete "every validator, formatter, and security hook must have CI coverage; commit lifecycle hooks must remain local";
  assert lib.assertMsg (shellcheckCorpusIds == ["shellcheck"]) "the corpus backend currently supports exactly shellcheck";
  assert lib.assertMsg (lib.all (name: definitions.${name}.role == "validator") (gitHooksCiIds ++ shellcheckCorpusIds)) "only validators may enter derived CI lint surfaces";
  assert lib.assertMsg (lib.all (name: builtins.elem "manual" localHooks.${name}.stages) diagnosticHookIds) "every devenv diagnostic hook must support the manual stage"; {
    inherit definitionNames definitions diagnosticHookIds localHooks;

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
      repo-validation-policy = import ../checks/repository/repo-validation-policy.nix {
        inherit definitionNames diagnosticHookIds pkgs;
        ciConfig = repoLints.config.configFile;
        ciHookIds = gitHooksCiIds;
        localConfig = localProjection.config.configFile;
        rejectEntry = definitions.reject-default-branch-commit.hook.entry;
      };
      shellcheck-corpus = import ../checks/shell/shellcheck-corpus.nix {inherit lib pkgs;};
    };
  }
