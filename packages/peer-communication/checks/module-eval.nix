# The program is on by default: with no configuration both backends deliver the
# skill to every runtime whose skills that backend delivers, and the router rule
# to every runtime whose rules it delivers. A per-runtime disable removes both from that runtime only;
# the global disable removes both everywhere.
{
  lib,
  harness,
  ...
}: let
  inherit (harness) evalDevenvModules evalHmModules harnessNames mkTest;
  # Whole-module evaluators: the config-form ones (evalHm, evalDevenv) turn
  # this default-on program off so it stays out of unrelated checks.
  backends = {
    devenv = config: evalDevenvModules [{inherit config;}];
    hm = config: evalHmModules [{inherit config;}];
  };
  # The retained delivery policy is this test's expectation oracle for which
  # runtimes get a skill or a router; production uses the runtime support
  # declaration.
  policy = import ../../../config/ai-delivery.nix {inherit lib;};
  optionPaths = import ../../../lib/ai/option-paths.nix {inherit lib;};
  inert = surface: backend:
    builtins.filter
    (runtime: (policy.definitions.${surface}.${runtime}.${backend}.primitive or null) == "notApplicable")
    harnessNames;
  pool = result: runtime: surface: lib.attrByPath (optionPaths.pool runtime surface) {} result.config;
  hasSkill = result: runtime: pool result runtime "skills" ? peer-communication;
  hasRule = result: runtime: pool result runtime "rules" ? peer-communication-router;
  skillText = result: runtime: builtins.readFile "${(pool result runtime "skills").peer-communication}/SKILL.md";
  forBackends = prefix: test:
    lib.mapAttrs' (backend: evaluate: let
      present = surface: result:
        lib.subtractLists (inert surface backend)
        (builtins.filter (runtime: lib.hasAttrByPath (optionPaths.pool runtime surface) result.options) harnessNames);
    in
      lib.nameValuePair "module-peer-communication-${backend}-${prefix}"
      (mkTest "peer-communication-${backend}-${prefix}" (test {
        inherit evaluate;
        ruleRuntimes = present "rules";
        skillRuntimes = present "skills";
        inert = surface: inert surface backend;
      })))
    backends;
in {
  checks =
    # Default config: every runtime gets the skill, every rule-capable runtime
    # gets the router, and nothing lands in the root pools.
    forBackends "default-delivers" ({
      evaluate,
      inert,
      ruleRuntimes,
      skillRuntimes,
    }: let
      result = evaluate {};
    in
      result.config.ai.programs.peer-communication.enable
      && lib.all (hasSkill result) (skillRuntimes result)
      && skillRuntimes result != []
      && lib.all (hasRule result) (ruleRuntimes result)
      && ruleRuntimes result != []
      && lib.hasInfix "load the peer-communication skill before your first reply" result.config.ai.claude.rules.peer-communication-router.text
      && lib.hasInfix "## Findings: surface, summarize, or defer" (skillText result "claude")
      && !(lib.any (hasRule result) (inert "rules"))
      && !(lib.any (hasSkill result) (inert "skills"))
      && !(result.config.ai.skills ? peer-communication)
      && !(result.config.ai.rules ? peer-communication-router))
    # A per-runtime disable removes both contributions there and nowhere else.
    // forBackends "runtime-disable" ({
      evaluate,
      ruleRuntimes,
      skillRuntimes,
      ...
    }: let
      result = evaluate {ai.programs.peer-communication.runtimes.claude.enable = false;};
    in
      !(hasSkill result "claude")
      && !(hasRule result "claude")
      && lib.all (hasSkill result) (lib.remove "claude" (skillRuntimes result))
      && lib.all (hasRule result) (lib.remove "claude" (ruleRuntimes result)))
    # The documented off switch removes the skill and the router everywhere.
    // forBackends "global-disable" ({
      evaluate,
      ruleRuntimes,
      skillRuntimes,
      ...
    }: let
      result = evaluate {ai.programs.peer-communication.enable = false;};
    in
      !(lib.any (hasSkill result) (skillRuntimes result))
      && !(lib.any (hasRule result) (ruleRuntimes result)));
}
