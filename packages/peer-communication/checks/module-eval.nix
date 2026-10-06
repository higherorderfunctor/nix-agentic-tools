# The program is on by default: with no configuration both backends deliver the
# skill to every runtime and the router rule to every runtime whose rules that
# backend delivers. A per-runtime disable removes both from that runtime only.
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
  # Home Manager does not deliver Copilot rules, so the HM module writes none.
  inertRules = {
    devenv = [];
    hm = ["copilot"];
  };
  hasSkill = result: runtime: result.config.ai.${runtime}.skills ? peer-communication;
  hasRule = result: runtime: result.config.ai.${runtime}.rules ? peer-communication-router;
  skillText = result: runtime: builtins.readFile "${result.config.ai.${runtime}.skills.peer-communication}/SKILL.md";
  forBackends = prefix: test:
    lib.mapAttrs' (backend: evaluate: let
      ruleRuntimes = result:
        lib.subtractLists inertRules.${backend}
        (builtins.filter (runtime: result.options.ai.${runtime} ? rules) harnessNames);
    in
      lib.nameValuePair "module-peer-communication-${backend}-${prefix}"
      (mkTest "peer-communication-${backend}-${prefix}" (test {
        inherit evaluate ruleRuntimes;
        inert = inertRules.${backend};
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
    }: let
      result = evaluate {};
    in
      result.config.ai.programs.peer-communication.enable
      && lib.all (hasSkill result) harnessNames
      && lib.all (hasRule result) (ruleRuntimes result)
      && ruleRuntimes result != []
      && lib.hasInfix "load the peer-communication skill before your first reply" result.config.ai.claude.rules.peer-communication-router.text
      && lib.hasInfix "## Findings: surface, summarize, or defer" (skillText result "claude")
      && !(lib.any (hasRule result) inert)
      && !(result.config.ai.skills ? peer-communication)
      && !(result.config.ai.rules ? peer-communication-router))
    # A per-runtime disable removes both contributions there and nowhere else.
    // forBackends "runtime-disable" ({
      evaluate,
      ruleRuntimes,
      ...
    }: let
      result = evaluate {ai.programs.peer-communication.runtimes.claude.enable = false;};
      others = lib.remove "claude" harnessNames;
    in
      !(hasSkill result "claude")
      && !(hasRule result "claude")
      && lib.all (hasSkill result) others
      && lib.all (hasRule result) (lib.remove "claude" (ruleRuntimes result)));
}
