# Shared helpers for AI CLI modules (copilot-cli, kiro-cli, devenv).
#
# Provides skill delivery entries and the `own` bundle
# builder that records reconciliation plans.
{lib}: let
  own = import ./own.nix {inherit lib;};
in {
  # ── File entry builders ──────────────────────────────────────────────

  # One skill tree as STAGED entries (`ai.<runtime>._generatedFiles`), for
  # every runtime and both backends; layer 1 and the files engine deliver them.
  #
  # A directory skill is one entry with a directory source, which the engine
  # walks into one link per leaf on both backends. A single-file skill becomes
  # its own `SKILL.md`.
  #
  # `recursive = false` with a directory source is Codex's shape, and it is a
  # measured consumer fact rather than a preference: Codex discovers a skill
  # when the skill DIRECTORY is itself a symlink, and not when the backend
  # creates a real directory of symlinked leaves.
  #
  # `builtins.readFileType` rather than `lib.isPath`, because a skill that
  # comes from a package is an interpolated STRING, and treating that as a
  # single file writes the path itself as the file's content. The source is
  # always interpolated: a path-typed tree then enters the store once, so a
  # relative symlink between two of its leaves still resolves.
  mkSkillFiles = {
    configDir,
    recursive ? true,
    skills,
  }:
    lib.mapAttrs' (
      name: source: let
        entry = {
          content.source = "${source}";
          surface = "skills";
        };
      in
        if (builtins.readFileType source) == "directory"
        then lib.nameValuePair "${configDir}/skills/${name}" (entry // {inherit recursive;})
        else
          assert lib.assertMsg recursive
          "mkSkillFiles: skill '${name}' must resolve to a directory";
            lib.nameValuePair "${configDir}/skills/${name}/SKILL.md" entry
    )
    skills;

  # ── Owned artifacts ──────────────────────────────────────────────────

  # Emit one `own` bundle AND the eval-visible record of its plan, from one
  # set of arguments. Every `own` caller in this repo goes through here.
  #
  # `own` ships content as data in a store-resident plan, so the emitted body
  # names neither the document it reconciles nor the bytes it will write, and
  # the plan file itself cannot be read back at eval: importing a derivation is
  # forbidden here, and discarding the plan's string context to make it
  # readable would drop the store references that keep a rendered command alive
  # in the generation's closure. `ai.<runtime>._ownPlans.<write entry>` is
  # therefore the ONLY eval-visible record of what a writer will do, and it
  # carries `own`'s own plan value rather than a caller-side mirror of it.
  #
  # `declared` is the one thing the plan cannot carry: a document target's
  # content is `builtins.toJSON value`, and `builtins.fromJSON` REFUSES a
  # string that refers to a store path, so a check cannot recover the value
  # from the plan. It is keyed by the same document path the target names.
  #
  # runtime: ai.<runtime> namespace that records the plan.
  mkOwnBundle = {
    backend,
    declared ? {},
    runtime,
    ...
  } @ args: let
    owned = own (builtins.removeAttrs args ["declared" "runtime"]);
    # The record is reached through a NESTED value, never merged into `owned`
    # with `//` and never behind a `cfg`-derived attribute NAME. `own`
    # validates its plan eagerly under `builtins.seq`, and the module system
    # walks a fragment's key structure while it is still collecting the very
    # definitions a `cfg.configDir`-derived `ledger` or `path` reads — forcing
    # the validation there is an infinite recursion, which is what a caller
    # that merged the bundle with `//` got. Only attribute VALUES may reach
    # into `owned`.
    record = {
      ai.${runtime}._ownPlans.${args.entryNames.write} = {
        inherit declared;
        # As lazy as an assignment: the source is one shared thunk that
        # nothing forces until an attribute is demanded.
        inherit (owned) plan;
      };
    };
  in
    if backend == "hm"
    then record // {home.activation = owned.config.home.activation;}
    else
      record
      // {inherit (owned.config) enterTest tasks;};
}
