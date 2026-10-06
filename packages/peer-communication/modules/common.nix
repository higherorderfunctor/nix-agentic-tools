# Peer-communication module, shared by the Home Manager and devenv backends.
#
# Ships the peer communication guide as an on-demand skill plus a short
# always-on router rule that tells an interactive session to load it. The
# guide is about 1,950 words; as an always-on rule it would be a per-turn cost
# in every session, including non-interactive delegates that report to an
# orchestrator and never write for a person. The router keeps the always-on
# cost to two sentences and lets those delegates skip the skill.
#
# The program is ENABLED BY DEFAULT (the factory's `enableDefault`): importing
# the module is the opt-in. `ai.programs.peer-communication.enable = false`
# turns it off everywhere, and
# `ai.programs.peer-communication.runtimes.<runtime>.enable = false` turns it
# off for one runtime. Text overrides use the factory's per-runtime pools:
# `ai.<runtime>.skills.peer-communication` and
# `ai.<runtime>.rules.peer-communication-router`.
#
# `backend` ("hm" or "devenv") selects which runtimes get the router: a
# runtime whose rules this backend does not deliver by policy
# (config/ai-delivery.nix, primitive "notApplicable" — today Copilot under
# Home Manager) gets none, so a default evaluation does not warn that a rule
# is set but not delivered. Such a runtime still gets the skill, whose
# description asks for it to be loaded in an interactive session.
{backend}: {lib, ...}: let
  policy = import ../../../config/ai-delivery.nix {inherit lib;};
  inert = runtime: (policy.definitions.rules.${runtime}.${backend}.primitive or null) == "notApplicable";
in {
  imports = [
    (import ../../../lib/ai/mkSkillPackageModule.nix {
      name = "peer-communication";
      enableDefault = true;
      enableDescription = "the peer-communication skill and its router rule in each enabled runtime";
      skills = _: {
        # A store-path string, the form the other skill packages hand over.
        peer-communication = "${../skills/peer-communication}";
      };
      rules = {runtime, ...}:
        if inert runtime
        then {}
        else {
          peer-communication-router = {
            text = "# Peer communication\n\nWhen you are talking with a person, load the peer-communication skill before your first reply and follow it for every reply after. Skip it when your brief says you run non-interactively and report to an orchestrator.";
          };
        };
    })
  ];
}
