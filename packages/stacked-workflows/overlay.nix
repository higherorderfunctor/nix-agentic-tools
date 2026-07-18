# Stacked-workflows content package — skills, references, fragments.
# Derivation: pkgs.stacked-workflows-content
# passthru provides eval-time access to fragments, references, and skills.
_: final: _prev: let
  inherit (final) lib;
  fragmentsLib = import ../../lib/fragments.nix {inherit lib;};

  # Exclude devenv/activation cruft that can accumulate inside source
  # skill directories. Pattern: `<32-lowercase-alnum>-<name>` (a Nix
  # store path basename) — these appear as dangling symlinks when a
  # stale devenv activation drops store-linked state into the source
  # tree. Nix's path import copies the working tree verbatim (no
  # .gitignore respect), so we filter them out here.
  cruftFilter = base: builtins.match "[0-9a-z]{32}-.+" base == null;

  skillsSrc = builtins.path {
    name = "stacked-workflows-skills-src";
    path = ./skills;
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
  skillsWithRefs = final.runCommand "stacked-workflows-skills" {} ''
    mkdir -p stage/skills stage/references
    cp -r ${skillsSrc}/. stage/skills/
    cp -r ${./references}/. stage/references/
    # Dereference the ../../../references symlinks into real files.
    cp -RL stage/skills $out
  '';

  # Single source of truth: skill name -> self-contained skill dir.
  # Names come from the SOURCE dir (eval-safe readDir, no IFD); values
  # are store-path strings into the deref'd derivation (accepted by the
  # factory via `isPathLike`; the devenv walker realizes them).
  skillNames = builtins.attrNames (
    lib.filterAttrs
    (n: kind: kind == "directory" && cruftFilter n)
    (builtins.readDir ./skills)
  );
  skills = lib.genAttrs skillNames (name: "${skillsWithRefs}/${name}");
in {
  stacked-workflows-content =
    final.runCommand "stacked-workflows-content" {} ''
      mkdir -p $out/{fragments,references,skills}
      cp -r ${./fragments}/. $out/fragments/
      cp -r ${./references}/. $out/references/
      cp -r ${skillsWithRefs}/. $out/skills/
    ''
    // {
      passthru = {
        fragments = {
          routing-table = fragmentsLib.mkFragment {
            text = builtins.readFile ./fragments/routing-table.md;
            description = "Stacked workflow skill routing table";
            source = "packages/stacked-workflows/fragments/routing-table.md";
            priority = 10;
          };
        };
        referencesDir = ./references;
        skillsDir = skillsWithRefs;
        inherit skills;
      };
    };
}
