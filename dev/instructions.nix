# dev/instructions.nix — the four generated instruction-file derivations.
#
# SINGLE SOURCE OF TRUTH for both consumers:
#   flake.nix  → packages.<system>.instructions-*  (CI, `nix build`, checks)
#   devenv.nix → dev/tasks/generate.nix            (working-tree materializer)
#
# Both MUST render identical bytes, and that is the whole point of this file.
# devenv `files.*` used to write the RAW `gen.*` text while the generate tasks
# copied treefmt-formatted derivation output — different bytes for AGENTS.md,
# all 15 .claude/rules/*, all 16 .kiro/steering/*, and copilot-instructions.md
# (only the 24-byte CLAUDE.md matched). Whichever writer ran last won. There
# is now exactly one renderer and one materializer.
#
# NOTE: the four derivation bodies are moved VERBATIM out of flake.nix so the
# resulting store paths stay bit-identical across the refactor — the migration
# is proven by store-path hash equality rather than a diff. Collapsing them
# into one `install -D` helper is a worthwhile follow-up, deliberately deferred
# so this change touches the mechanism and nothing else.
{
  lib,
  pkgs,
  treefmt-nix,
}: let
  # Fragment composition. `import` is memoized, so both consumers share one
  # evaluation.
  gen = import ./generate.nix {inherit lib pkgs;};

  # treefmt for use inside derivations. Same config as treefmt.nix
  # but with projectRootFile disabled — no .git in nix sandbox.
  fmtDrv =
    (treefmt-nix.lib.evalModule pkgs (
      lib.recursiveUpdate (import ../treefmt.nix) {projectRootFile = null;}
    ))
    .config
    .build
    .wrapper;

  # Helper: runCommand that formats $out with treefmt before finishing.
  # All generated content derivations should use this instead of bare
  # runCommand to ensure store output is pre-formatted.
  # $out files are cp'd from writeText store paths (read-only).
  # chmod makes the build output writable so treefmt can format
  # in place. This is the derivation's own $out being constructed,
  # not an existing store path — safe and expected.
  runFmt = name: attrs: script:
    pkgs.runCommand name (attrs // {nativeBuildInputs = (attrs.nativeBuildInputs or []) ++ [fmtDrv];}) ''
      ${script}
      chmod -R u+w $out
      treefmt --no-cache --walk filesystem --tree-root $out
    '';
in {
  # runFmt builds the instruction derivations below (treefmt runs inside
  # the runCommand). Re-exported alongside gen/fmtDrv for external callers.
  inherit gen fmtDrv runFmt;

  agents = runFmt "instructions-agents" {} ''
    mkdir -p $out
    cp ${pkgs.writeText "AGENTS.md" gen.agentsMd} $out/AGENTS.md
  '';

  claude = let
    files =
      {"CLAUDE.md" = gen.claudeMd;}
      // lib.mapAttrs' (
        name: content: lib.nameValuePair "rules/${name}" content
      )
      gen.claudeFiles;
  in
    runFmt "instructions-claude" {} (
      "mkdir -p $out/rules\n"
      + lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          name: content: "cp ${pkgs.writeText (baseNameOf name) content} $out/${name}"
        )
        files
      )
    );

  copilot = let
    files =
      lib.mapAttrs' (
        name: content:
          lib.nameValuePair (
            if name == "copilot-instructions.md"
            then name
            else "instructions/${name}"
          )
          content
      )
      gen.copilotFiles;
  in
    runFmt "instructions-copilot" {} (
      "mkdir -p $out/instructions\n"
      + lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          name: content: "cp ${pkgs.writeText (baseNameOf name) content} $out/${name}"
        )
        files
      )
    );

  kiro = runFmt "instructions-kiro" {} (
    "mkdir -p $out\n"
    + lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: content: "cp ${pkgs.writeText name content} $out/${name}"
      )
      gen.kiroFiles
    )
  );
}
