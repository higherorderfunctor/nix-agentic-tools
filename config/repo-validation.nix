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

  # Markdown TABLE CELL COUNTS. Two linters, deliberately, and the pairing is
  # the whole point — see the disjoint coverage table below before "deduplicating"
  # them.
  #
  # THE DEFECT. A GFM table is only a table when the header row and the
  # delimiter row have the same number of cells. Disagree and remark stops
  # seeing a table at all, `proseWrap = "always"` reflows the block as prose,
  # and it renders as a wall of pipes. It reached main once
  # (`dev/references/agnix.md`) and stayed, because the `<!-- prettier-ignore -->`
  # that someone added to quiet the formatter also hid it from
  # `checks.formatting` entirely.
  #
  # THE CAUSE is almost always one unescaped pipe. A row is split into cells at
  # BLOCK level, before inline parsing, so a backtick gives a pipe no
  # protection: writing `|| true` in a cell silently produces extra cells.
  # Escape it (`\|\| true`) and it is one cell again.
  #
  # WHY BOTH TOOLS. They share the rule NUMBER and cover disjoint halves of it,
  # which is exactly the trap that makes one of them look redundant. Measured:
  #
  #                                        rumdl MD056   markdownlint MD056
  #   cause: valid table, excess body cell      no             YES
  #   break: header/delimiter disagree          YES            no
  #
  # markdownlint goes blind on the break because its parser stops recognizing a
  # table, so its MD056 has nothing left to check. rumdl goes blind on the
  # cause. Drop either and half the class stops being caught.
  #
  # ORDER IS BY SPEED, primary first. Measured over this corpus with only MD056
  # enabled: rumdl 0.04s, markdownlint 8.2s (0.00s vs 0.19s on a single file).
  # rumdl is the Rust primary and is effectively free; markdownlint is the Node
  # backup that exists solely to cover the gap above, and its cost is paid only
  # for that.
  #
  # NOT a formatter question. `dev/fragments/markdown-formatting/` records that
  # no Rust markdown formatter joins a split inline code span, which is why
  # prettier owns formatting and keeps owning it. This is the LINTER slot beside
  # `doubled-words` and `split-code-spans`, and it reopens none of that.
  markdownlintTablesConfig = pkgs.writeText "markdownlint-tables.jsonc" ''
    { "default": false, "MD056": true }
  '';

  markdownTableCells = pkgs.writeShellApplication {
    name = "markdown-table-cells";
    extraShellCheckFlags = shellStrict.shellcheckFlags;
    inherit (shellStrict) bashOptions;
    text = ''
      ${shellStrict.shoptHeader}
      # Both tools exit non-zero on a finding. Run BOTH before failing, so one
      # commit reports every broken table rather than only the first half of
      # the class.
      rc=0
      # OUR overlay packages, not `pkgs.rumdl` / `pkgs.markdownlint-cli2` —
      # those are whatever the nixpkgs pin happens to carry, and the point
      # of absorbing both was to track upstream on this repo's own sweep.
      ${pkgs.ai.devTools.rumdl}/bin/rumdl check --enable MD056 --no-config -- "$@" || rc=1
      ${pkgs.ai.devTools.markdownlint-cli2}/bin/markdownlint-cli2 \
        --config ${markdownlintTablesConfig} -- "$@" || rc=1
      if [ "$rc" -ne 0 ]; then
        printf '%s\n' >&2 \
          "" \
          "A markdown table needs the SAME cell count in its header row and its" \
          "delimiter row, and no row may carry more cells than the header (the" \
          "excess is silently dropped on render)." \
          "" \
          "The usual cause is one unescaped pipe. A row is split into cells BEFORE" \
          "inline parsing runs, so a backtick gives a pipe no protection: writing" \
          "a shell operator in a cell quietly adds cells. Escape it." \
          "" \
          # The backticks are LITERAL — these two lines show a markdown code
          # span, which is exactly the construct that causes the defect. Single
          # quotes are what keeps them literal; shellcheck flags SC2016 on any
          # single-quoted backtick in case a command substitution was meant.
          # shellcheck disable=SC2016
          '  broken:  | id | `|| true` on the hook |' \
          '  fixed:   | id | `\|\| true` on the hook |'
      fi
      exit "$rc"
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
    markdown-table-cells = {
      role = "validator";
      hook = {
        enable = true;
        name = "markdown-table-cells";
        entry = lib.getExe markdownTableCells;
        files = "\\.md$";
        # Same file set the other markdown scanners walk, for the reason
        # checks/markdown-scan.nix exists: one exclusion list, not three.
        excludes = ["^docs/plans/kiro-v3-research-raw/" "^docs/plan\\.md$"];
        stages = ["pre-commit"];
      };
      stop = "judgment";
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
