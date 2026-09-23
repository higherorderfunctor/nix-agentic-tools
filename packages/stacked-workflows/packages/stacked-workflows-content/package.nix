# Stacked-workflows content package — skills, references, fragments.
# Derivation: pkgs.stacked-workflows-content
# passthru provides eval-time access to fragments, references, and skills.
{
  pkgs,
  fragmentsLib,
  repoPath,
  traceSource,
  ...
}: let
  inherit (pkgs) lib;

  # Exclude devenv/activation cruft that can accumulate inside source
  # skill directories. Pattern: `<32-lowercase-alnum>-<name>` (a Nix
  # store path basename) — these appear as dangling symlinks when a
  # stale devenv activation drops store-linked state into the source
  # tree. Nix's path import copies the working tree verbatim (no
  # .gitignore respect), so we filter them out here.
  cruftFilter = base: builtins.match "[0-9a-z]{32}-.+" base == null;

  skillsSrc = builtins.path {
    name = "stacked-workflows-skills-src";
    path = ../../skills;
    filter = path: _type: cruftFilter (baseNameOf path);
  };

  # Self-contained skill dirs with their shared references materialized
  # as REAL files. Source skills carry `references/*.md` as relative
  # symlinks (`../../../references/*`) into the package-level
  # `./references`; those resolve in the source tree but DANGLE once
  # only `./skills` is imported (no sibling `references/`). We
  # reassemble the sibling layout and `cp -L` (dereference) so each
  # skill dir is portable to any install scope (HM-global,
  # devenv-project) and ecosystem — no shared references dir needed,
  # and the single source of a shared ref stays `./references/<x>.md`.
  skillsWithRefs =
    pkgs.runCommand "stacked-workflows-skills" {
      # NOT UNUSED — deleting either attr silently breaks direnv. Forcing them
      # is what reads every skill and reference file during evaluation, which
      # is the only thing that puts those files on direnv's watch list; the
      # digests themselves are incidental. Nothing above registers them:
      # `builtins.path` and the `${../../references}` store copy are
      # whole-DIRECTORY copies, which register only the directory and so yield
      # no watch, `readDir` yields names only, and the skills reach
      # `ai.skills` as store-path strings (so nothing emits a per-file entry
      # against the source tree the way `dev/skills/` gets one). Measured
      # 2026-09-22 by elimination plus an observed reload. The full mechanism
      # is in lib/traceSource.nix, along with the 2026-09-23 measurement that
      # `devenv hook` has no watch set at all — which is what would retire
      # this pair once the operator migrates off direnv.
      referencesTrackedInputs = traceSource.registerTrackedInputs ../../references;
      skillsTrackedInputs = traceSource.registerTrackedInputs ../../skills;
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.coreutils}/bin/mkdir -p stage/skills stage/references
      ${pkgs.coreutils}/bin/cp -r ${skillsSrc}/. stage/skills/
      ${pkgs.coreutils}/bin/cp -r ${../../references}/. stage/references/
      # Dereference the ../../../references symlinks into real files.
      ${pkgs.coreutils}/bin/cp -RL stage/skills $out
    '';

  # Single source of truth: skill name -> self-contained skill dir.
  # Names come from the SOURCE dir (eval-safe readDir, no IFD); values
  # are store-path strings into the deref'd derivation (accepted by the
  # factory via `isPathLike`; the devenv walker realizes them).
  skillNames = builtins.attrNames (
    lib.filterAttrs
    (n: kind: kind == "directory" && cruftFilter n)
    (builtins.readDir ../../skills)
  );
  skills = lib.genAttrs skillNames (name: "${skillsWithRefs}/${name}");
in
  pkgs.runCommand "stacked-workflows-content" {} ''
    mkdir -p $out/{fragments,references,skills}
    cp -r ${../../fragments}/. $out/fragments/
    cp -r ${../../references}/. $out/references/
    cp -r ${skillsWithRefs}/. $out/skills/
  ''
  // {
    passthru = {
      fragments = import ../../lib/fragments.nix {inherit fragmentsLib lib repoPath;};
      referencesDir = ../../references;
      skillsDir = skillsWithRefs;
      inherit skills;
    };
  }
