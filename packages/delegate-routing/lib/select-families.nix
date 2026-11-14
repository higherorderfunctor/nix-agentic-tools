# Non-empty selector fields are conjunctive; selectors themselves are alternatives.
{lib}: let
  inherit (import ./vocabulary.nix) tiers;
  tierRanks = builtins.listToAttrs (lib.imap0 (value: name: {inherit name value;}) tiers);
  automatic = {
    runtime,
    extraRuntimes,
    manualExternalDelegates,
  }:
    [runtime] ++ lib.subtractLists manualExternalDelegates (lib.unique extraRuntimes);
  flatten = families:
    lib.concatMap
    (vendor: lib.mapAttrsToList (name: family: family // {inherit name vendor;}) families.${vendor})
    (builtins.attrNames families);
  select = families: selectors:
    lib.sort
    (a: b: tierRanks.${a.tier} < tierRanks.${b.tier})
    (builtins.filter
      (family:
        lib.any
        (selector: let
          fields = lib.filterAttrs (_: values: values != []) selector;
          values = {
            families = family.name;
            tiers = family.tier;
            vendors = family.vendor;
          };
        in
          fields != {} && lib.all (field: builtins.elem values.${field} fields.${field}) (builtins.attrNames fields))
        selectors)
      (flatten families));
in {
  inherit automatic flatten select;

  # Rendered skills and acceptance inventory share this view. An explicit
  # technique enable cannot advertise a workflow the CLI config disables.
  effectiveTechniques = config: let
    cli = config.ai.kiro.cli or {};
    portable = config.ai.programs.delegate-routing;
    agentFilesAvailable =
      (config.ai.claude.enable or false)
      && (import ../../../lib/ai/ai-common.nix {inherit lib;}).resolveOverride {
        topValue = portable.enable;
        cliValue = portable.runtimes.claude.enable or null;
      };
    workflowAvailable =
      (cli.workflows.enable or false)
      && (cli.native.settings.chat.enableWorkflows or null) != false;
  in
    lib.mapAttrs (runtime: settings:
      lib.mapAttrs (name: node:
        node
        // {
          enable =
            node.enable
            && (runtime != "kiro" || name != "run_workflow" || workflowAvailable)
            && (runtime != "claude" || name != "Agent with generated agent file" || agentFilesAvailable);
        })
      settings.techniques)
    config.ai.programs.delegate-routing.runtimes;

  # Concrete launches require a known maker; unknown offers remain inspectable.
  validateId = catalog: offers: id: let
    matching =
      if offers == null
      then []
      else lib.filter (offer: offer.model == id) offers;
    identities =
      if offers == null
      then [id]
      else lib.unique (map (offer: offer.id) matching);
  in
    if offers != null && matching == []
    then throw "delegate-routing: model `${id}` is not offered by the selected CPA client."
    else if lib.length identities != 1
    then throw "delegate-routing: ambiguous launch identity `${id}`."
    else if (catalog.models.${lib.head identities}.maker or null) == null
    then throw "delegate-routing: concrete model `${id}` requires a catalog identity with a maker."
    else id;
}
