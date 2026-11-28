# Both backends require opt-in; a runtime can opt out of both contributions.
{
  lib,
  harness,
  ...
}: let
  inherit (harness) checkRows evalDevenv evalHm harnessNames mkTest;
  optionPaths = import ../../../lib/ai/option-paths.nix {inherit lib;};
  backends = {
    devenv = evalDevenv;
    hm = evalHm;
  };
  # Copilot only writes project-local rules and skills. Pin the membership
  # independently of the production capability declaration and option presence.
  expectedRuntimes = backend:
    ["claude" "codex"] ++ lib.optional (backend == "devenv") "copilot" ++ ["kimchi" "kiro"];
  keys = {
    rules = "peer-communication-router";
    skills = "peer-communication";
  };
  pool = result: runtime: surface: lib.attrByPath (optionPaths.pool runtime surface) {} result.config;
  recipients = result: surface:
    builtins.filter (runtime: builtins.hasAttr keys.${surface} (pool result runtime surface)) harnessNames;
  rootAbsent = result: lib.all (surface: !(builtins.hasAttr keys.${surface} result.config.ai.${surface})) (builtins.attrNames keys);
  rows = backend: evaluate: let
    defaults = evaluate {};
    enabled = evaluate {ai.programs.peer-communication.enable = true;};
    optedOut = evaluate {
      ai.programs.peer-communication = {
        enable = true;
        runtimes.claude.enable = false;
      };
    };
    program = defaults.config.ai.programs.peer-communication;
    runtimes = expectedRuntimes backend;
    remaining = lib.remove "claude" runtimes;
    # Read the supplied text and directory, not just the contribution keys:
    # an empty router or a different skill can still have the expected name.
    router = (pool enabled "claude" "rules").peer-communication-router.text;
    skill = builtins.readFile "${(pool enabled "claude" "skills").peer-communication}/SKILL.md";
  in
    {
      "Claude router tells interactive sessions to load the skill before replying" =
        lib.hasInfix "load the peer-communication skill before your first reply" router;
      "default router does not reach any runtime before opt-in" = recipients defaults "rules" == [];
      "default skill does not reach any runtime before opt-in" = recipients defaults "skills" == [];
      "default state leaves consumer root pools free of package entries" = rootAbsent defaults;
      "enabled router reaches exactly the runtimes with a rule writer" = recipients enabled "rules" == runtimes;
      "enabled skill reaches exactly the runtimes with a skill writer" = recipients enabled "skills" == runtimes;
      "opting Claude out removes only Claude's router" = recipients optedOut "rules" == remaining;
      "opting Claude out removes only Claude's skill" = recipients optedOut "skills" == remaining;
    }
    # Both backends share the skill directory and runtime option declarations.
    // lib.optionalAttrs (backend == "devenv") {
      "Claude skill directory contains the guide's findings section" =
        lib.hasInfix "## Findings: surface, summarize, or defer" skill;
      "default runtime switches inherit instead of silently opting in or out" =
        lib.all (runtime: program.runtimes.${runtime}.enable == null) harnessNames;
    };
in {
  checks = lib.mapAttrs' (backend: evaluate:
    lib.nameValuePair "module-peer-communication-${backend}"
    (mkTest "peer-communication-${backend}" (checkRows "peer communication (${backend})" (rows backend evaluate))))
  backends;
}
