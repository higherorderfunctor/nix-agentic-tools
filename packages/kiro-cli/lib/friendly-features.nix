# Friendly switches and their measured rollout/client-setting dependencies.
# Shared by the module and the owner's consumer expectations.
{
  featureSettingImplications = {
    codeToSpec = "enableC2s";
    workflows = "enableWorkflows";
  };
  friendlyRolloutFeatures = {
    backgroundExecution = "background_execution";
    codeToSpec = "c2s";
    kvim = "kvim";
    sandbox = "local_sandbox";
    workflows = "workflows";
  };
}
