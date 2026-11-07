# Friendly switches and their measured rollout/client-setting dependencies.
# Shared by the module and the owner's consumer expectations. `workflows` has
# no rollout since 3.1.0: only its client setting gates it.
{
  featureSettingImplications = {
    codeToSpec = "enableC2s";
    workflows = "enableWorkflows";
  };
  friendlyRolloutFeatures = {
    backgroundExecution = "background_execution";
    codeToSpec = "c2s";
    kvim = "kvim";
  };
}
