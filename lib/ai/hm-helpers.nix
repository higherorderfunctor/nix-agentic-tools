# Shared helpers for AI CLI modules (copilot-cli, kiro-cli, devenv).
#
# Provides settings utilities, skill delivery entries, and the router-owned
# bundle builder that records reconciliation plans.
{lib}: let
  aiCommon = import ./ai-common.nix {inherit lib;};
  own = import ./own.nix {inherit lib;};
in {
  # ── Settings utilities ──────────────────────────────────────────────

  # Delegated to lib/ai-common.nix (single source of truth).
  inherit (aiCommon) filterNulls;

  # ── File entry builders ──────────────────────────────────────────────

  # One skill tree as DELIVERY entries, for every runtime and both backends.
  #
  # A directory skill is one entry with a directory source: Home Manager
  # expands it natively and the router walks it for devenv, which is the single
  # walk that replaced three hand-written ones. A single-file skill becomes its
  # own `SKILL.md`.
  #
  # `recursive = false` with a directory source is Codex's shape, and it is a
  # measured consumer fact rather than a preference: Codex discovers a skill
  # when the skill DIRECTORY is itself a symlink, and not when the backend
  # creates a real directory of symlinked leaves.
  #
  # `executable = null` is load-bearing everywhere: a skill tree may ship a
  # script, and stating a mode here would clear its executable bit at link
  # time.
  #
  # `builtins.readFileType` rather than `lib.isPath`, because a skill that
  # comes from a package is an interpolated STRING, and treating that as a
  # single file writes the path itself as the file's content — the bug the
  # upstream skill helper has.
  mkSkillFiles = {
    configDir,
    recursive ? true,
    skills,
  }:
    lib.mapAttrs' (
      name: source:
        if (builtins.readFileType source) == "directory"
        then
          lib.nameValuePair "${configDir}/skills/${name}" {
            content.source = source;
            executable = null;
            inherit recursive;
          }
        else
          assert lib.assertMsg recursive
          "mkSkillFiles: skill '${name}' must resolve to a directory";
            lib.nameValuePair "${configDir}/skills/${name}/SKILL.md" {
              # ALWAYS `source`, never a path-vs-string test. A skill that
              # comes from a package is an interpolated STRING holding a store
              # path, and routing that to `text` writes the PATH as the file's
              # body — the same upstream bug the directory branch above avoids,
              # reached through the single-file branch instead.
              content.source = source;
              executable = null;
            }
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

  # NOTE: Kiro hook files used to be written here by `mkHooksActivationScript`,
  # whose prune (`rm -f "$HOOKS_DIR"/*.json`) lived INSIDE the caller's
  # `mkIf (hooks != {})` gate: taking the hook surface from N to zero never
  # emitted the entry, so the prune never ran and every previously written hook
  # kept firing forever. They ride `own` now, whose ledger prunes
  # unconditionally and claims only the files it wrote. Kiro steering uses the
  # ordinary runtime-files symlink sink.
}
