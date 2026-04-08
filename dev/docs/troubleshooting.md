# Troubleshooting

Common issues and their solutions.

## MCP Server Not Starting

**Symptom:** CLI reports "failed to connect" or "server not found" for
an MCP server.

**Causes and fixes:**

1. **Missing credentials.** Servers that require tokens (github-mcp,
   kagi-mcp) will fail to start without credentials configured. Check
   the [credential requirements](./guides/mcp-servers.md) for your
   server and add `settings.credentials.file` or
   `settings.credentials.helper`.

2. **Secret file doesn't exist.** If using `credentials.file`, ensure
   the file exists at the specified path before the server starts.
   With sops-nix, the file is created during activation -- if you
   switch home-manager config before sops runs, the file won't exist
   yet.

3. **Wrong binary path.** If building from an older overlay, the store
   path may not match. Run `nix build .#<server>` to verify the
   package builds, then `home-manager switch` to update.

4. **Python path pollution.** The MCP entry builder automatically sets
   `PYTHONPATH=""` and `PYTHONNOUSERSITE=true` to prevent parent
   process Python paths from breaking Python-based servers. If you're
   wiring servers manually, include these env vars.

## Stale Skill Symlinks

**Symptom:** Claude Code reports "skill not found" or shows outdated
skill content after a config change.

**Causes and fixes:**

1. **DevEnv stale files.** DevEnv recreates config on shell entry. Exit
   and re-enter the devenv shell:

   ```bash
   exit
   devenv shell
   ```

2. **Home-manager stale symlinks.** After removing a skill from config,
   run `home-manager switch` to clean up old symlinks. If symlinks
   point to missing store paths (after garbage collection), switch
   again.

3. **Auto-clean on shell entry.** The devenv shell hook includes
   automatic cleanup of stale skill symlinks. If this isn't running,
   ensure you've imported `devenvModules.default`.

## Credentials Not Working

**Symptom:** Server starts but returns authentication errors.

**Causes and fixes:**

1. **Wrong secret format.** The credential file must contain the raw
   token value only -- no trailing newline, no JSON wrapper, no
   `export` prefix. Check with:

   ```bash
   cat -A /run/secrets/github-token
   # Should show just the token, ending with $
   ```

2. **Helper returns extra output.** If using `credentials.helper`, the
   command must output only the secret on stdout. Any extra output
   (warnings, prompts) will be included in the token value. Test:

   ```bash
   pass show github/mcp-token | wc -l
   # Should be 1
   ```

3. **attrTag conflict.** You cannot set both `file` and `helper` on
   the same credential. The module system will report a type error
   at eval time.

## Settings Not Persisting

**Symptom:** Settings revert after restarting the shell or switching
config.

**Causes and fixes:**

1. **DevEnv overwrites on entry.** DevEnv-generated settings files
   (`.claude/settings.json`, etc.) are recreated every time you enter
   the shell. This is by design -- project-local config is ephemeral.
   For persistent settings, use home-manager.

2. **mkDefault priority.** The `ai.*` module injects values at
   `mkDefault` priority (1000). If another module also sets the same
   key at `mkDefault`, the last one evaluated wins (non-deterministic).
   Use explicit normal priority (just `=`) for values you want to
   guarantee.

3. **Settings merge, not replace.** The HM settings activation script
   uses `jq -s '.[0] * .[1]'` to merge Nix-declared settings into
   existing config. This means Nix settings overlay mutable settings
   but don't delete keys not present in Nix. To remove a key, you may
   need to manually edit the config file.

## Overlay Packages Not Found

**Symptom:** `pkgs.nix-mcp-servers` or `pkgs.git-absorb` is not
available.

**Causes and fixes:**

1. **Overlay not applied.** Ensure you've added the overlay to your
   nixpkgs configuration:

   ```nix
   nixpkgs.overlays = [inputs.nix-agentic-tools.overlays.default];
   ```

2. **DevEnv overlay access.** DevEnv does not auto-apply overlays.
   Compose them manually:

   ```nix
   mcpPkgs = pkgs.extend (import "${inputs.nix-agentic-tools}/packages/mcp-servers" {
     inherit inputs;
   });
   ```

3. **Follows mismatch.** If your flake uses `inputs.nixpkgs.follows`
   and the nixpkgs version is very different from what nix-agentic-tools
   expects, some packages may fail to evaluate. Pin to a compatible
   nixpkgs version.

## nix flake check Failures

**Symptom:** `nix flake check` reports errors after making changes.

**Causes and fixes:**

1. **Structural check failures.** The structural check validates
   cross-references between flake outputs, module registrations, and
   overlay exports. If you renamed or removed something, grep for the
   old name across the repo.

2. **Formatting errors.** Run `treefmt` to fix formatting:

   ```bash
   treefmt
   ```

3. **Spelling errors.** The cspell check validates spelling. Add
   project-specific words to `.cspell.json` if needed.

4. **Dead code.** `deadnix` flags unused variables in Nix files.
   Remove or use the flagged bindings.

## Module Assertion Failures

**Symptom:** `home-manager switch` fails with an assertion message.

**Common assertions:**

- **"ai.copilot.enable requires programs.copilot-cli"** -- Import the
  copilot-cli module or use `homeManagerModules.default` which
  includes all modules.

- **"ai.kiro.enable requires programs.kiro-cli"** -- Same: import the
  kiro-cli module.

- **"ai has shared config but no CLIs enabled"** -- You set
  `ai.skills` or `ai.instructions` but didn't enable any CLI. Set at
  least one of `claude.enable`, `copilot.enable`, `kiro.enable`.

- **"programs.git.settings.pull.ff conflicts with
  stacked-workflows.gitPreset"** -- Remove `pull.ff` from your git
  settings or set `stacked-workflows.gitPreset = "none"`. Since Git
  2.34, `pull.ff = "only"` overrides `pull.rebase = true`.
