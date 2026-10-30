# One sample per portable field; a new field needs an explicit probe value.
{lib}: let
  settingsFields = (import ../ai/ai-common.nix {inherit lib;}).normalizedSettingsFields;
  samples.reasoningEffort = "high";
in {
  requestFields = surface:
    if surface == "settings"
    then settingsFields
    else [null];
  settingSample = field: samples.${field} or (throw "warning sample missing for ai.settings.${field}");
  inherit settingsFields;
}
