[
  # pi deliberately reads project trust from its global settings manager so a
  # project cannot grant itself trust. Kimchi reads every other key below from
  # ~/.config/kimchi/harness/settings.json directly, bypassing pi's merged
  # global/project SettingsManager. A project settings file is therefore a
  # silent no-op for all of them.
  "defaultProjectTrust"
  "fermentV2"
  "hidePhaseChanges"
  "modelMetadata"
  "modelRoles"
  "multiModel"
  "resources"
  "shellProfileApiKeyMigrationDismissed"
  "statusLine"
]
