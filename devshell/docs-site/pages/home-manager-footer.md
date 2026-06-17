## Priority and Override Patterns

All `ai.*` values are injected at `mkDefault` priority (1000). To
override for a specific CLI:

```nix
# Per-CLI model selection (each CLI owns its own settings)
programs.claude-code.settings.model = "claude-sonnet-4";
programs.copilot-cli.settings.model = "gpt-4o";
```

For git config, `stacked-workflows.gitPreset` also uses `mkDefault` on
every leaf, so you can override individual git settings at normal
priority in `programs.git.settings`.
