# One sample per portable field; a new field needs an explicit probe value.
{lib}: let
  settingsFields = (import ../ai/ai-common.nix {inherit lib;}).normalizedSettingsFields;
  samples = {
    inference = {
      key = (import ../redact {inherit lib;}).file "/run/secrets/ai-inference-key";
      url = "http://127.0.0.1:8317";
    };
    reasoningEffort = "high";
  };
  settingSample = field: samples.${field} or (throw "warning sample missing for ai.settings.${field}");
in {
  requestFields = surface:
    if surface == "settings"
    then settingsFields
    else [null];
  resolvedSettingSample = field:
    if field == "inference"
    then
      samples.inference
      // {
        backend = "cliproxyapi";
        credentials = [];
      }
    else settingSample field;
  inherit settingSample settingsFields;
}
