# `ai.copilot.configDir` — per-backend defaults

> **Status:** plan only, awaiting review.
>
> **Goal:** keep the `configDir` option name; diverge its default per
> backend so HM targets Copilot CLI's canonical personal dir and
> devenv keeps its current project-scoped path. Prior art:
> `ai.claude.buddy` was declared only in `hm.options` before removal
> (commit `d0d73bf`).

## The pattern

Today mkCopilot.nix declares `configDir` at the record's top-level
`options = { … }`, which hmTransform / devenvTransform fold into both
backends identically. Buddy-era prior art showed a different pattern:
backend-specific options live in `hm.options` / `devenv.options`
respectively, and the same attribute path
(`ai.<cli>.<option>`) can carry a **different type or default** in each
backend because each backend's module only sees its own declaration.

For `configDir` we want:

- Same attribute name: `ai.copilot.configDir`.
- Same type: `lib.types.str`.
- Same description (HOME-relative for HM, project-relative for devenv
  is conceptually the same "config dir" idea).
- **Different default value per backend.**

Declared twice — once in `hm.options`, once in `devenv.options`.

## Current state audit

`packages/copilot-cli/lib/mkCopilot.nix:38-42`:

```nix
configDir = lib.mkOption {
  type = lib.types.str;
  default = ".config/github-copilot";
  description = "Config directory relative to HOME / devenv root.";
};
```

Used by:

- HM block: `mcpConfigPath = "$HOME/${cfg.configDir}/mcp-config.json"`;
  `home.file."${cfg.configDir}/…"` for lsp-config, agents, skills,
  mcp-config, instructions, copilot-instructions, settings activation.
- Devenv block: `files."${cfg.configDir}/…"` for same set.

Per the research captured in `docs/unified-instructions-design.md`
(copilot section): Copilot CLI's canonical personal config dir is
`~/.copilot/` (`COPILOT_HOME` overridable). `~/.config/github-copilot/`
belongs to the `gh-copilot` gh-extension, **not** Copilot CLI.

## Scope — what ships this pass

1. **Move `configDir` out of shared options.** Remove the declaration
   from the shared `options = { … }` block in mkCopilot.nix.

2. **Re-declare in `hm.options`** with HM-appropriate default:

   ```nix
   hm = {
     options = {
       configDir = lib.mkOption {
         type = lib.types.str;
         default = ".copilot";
         description = ''
           Personal config dir relative to HOME. Default
           `.copilot` matches Copilot CLI's canonical location
           (COPILOT_HOME). Override if the CLI is configured to
           read from a different location.
         '';
       };
     };
     …
   };
   ```

3. **Re-declare in `devenv.options`** preserving the current default:

   ```nix
   devenv = {
     options = {
       configDir = lib.mkOption {
         type = lib.types.str;
         default = ".config/github-copilot";
         description = ''
           Project-scope config dir relative to devenv root. Keeps
           the legacy path; separate design question whether devenv
           should target Copilot's native `.github/*` project layout
           (not in scope here).
         '';
       };
     };
     …
   };
   ```

4. **Leave the bodies of `hm.config` and `devenv.config` unchanged.**
   Both already read `cfg.configDir`; the per-backend option
   declarations resolve each reference to its backend's default.

5. **Update existing module-eval tests** that hard-code the HM path
   `.config/github-copilot/`. Grep turns up ~6-8 tests across Copilot
   HM assertions (mcp-config, lsp-config, agents, skills,
   instructions, copilot-instructions, settings). Each becomes
   `.copilot/…` for HM assertions; devenv tests keep
   `.config/github-copilot/…`.

6. **Commit + journal entry.**

## Breaking-change / migration notes

- HM default path changes. Consumers with `ai.copilot.enable = true`
  but no explicit `configDir` will see their files move from
  `~/.config/github-copilot/…` to `~/.copilot/…` on next
  `home-manager switch`. The old dir remains until the user cleans
  it up; Copilot CLI starts reading the new dir (which is what it
  expects natively).
- Consumers who relied on the old HM path can pin it:
  `ai.copilot.configDir = ".config/github-copilot";`.
- Devenv default is unchanged — no migration there.
- Out of this pass's commit: release notes / CHANGELOG entry. If we
  don't have one today, worth flagging as a follow-up housekeeping
  item rather than blocking.

## Out of scope (tracked follow-ups)

- **Devenv project-scope restructure.** Moving devenv output from
  `.config/github-copilot/*` to the native `.github/*` layout
  (`.github/copilot-instructions.md`, `.github/instructions/`,
  `.github/agents/`, root-level `AGENTS.md`). Both cloud Copilot
  and local Copilot CLI read the `.github/*` layout when it exists;
  devenv's job is project-scope, so this layout is more correct. Out
  of scope here because it's a deeper reshape (new filenames, new
  locations, existing tests rewrite, more to migrate).
- **Cloud Copilot vs local Copilot differentiation.** Cloud reads
  only repo-scope (`.github/*` + `AGENTS.md`). Changing the HM
  default affects only local; cloud is already covered today by
  devenv's output (even at the legacy path, if a CI task writes the
  same files into `.github/` it works). Any deliberate cloud-vs-local
  split belongs with the devenv restructure above, not here.
- **Renaming `configDir` to something less ambiguous** (e.g.,
  `hmConfigDir` / `projectConfigDir`). Not doing — user indicated
  they want to keep `configDir`.
- **Deprecation warning infrastructure.** No general deprecation
  facility in the factory today. Release notes are the fallback.

## Plan → plan.md backlog bullet update

The existing "Copilot path correctness" was a stray inline remark in
this session, not a formal bullet. After shipping, add a brief
follow-up bullet covering the deferred devenv project-scope
restructure so it doesn't get lost.

## Size estimate

~15 lines factory + ~6 test-path string replacements + 1 commit.

## Review checklist

- [ ] `configDir` is no longer in the shared `options` block.
- [ ] `hm.options.configDir` default = `.copilot`.
- [ ] `devenv.options.configDir` default unchanged
      (`.config/github-copilot`).
- [ ] Descriptions reflect each backend's scope.
- [ ] Module-eval HM tests updated to the new path.
- [ ] Module-eval devenv tests unchanged.
- [ ] Commit message flags the breaking HM default change.
- [ ] Devenv project-scope restructure captured as a deferred
      follow-up in plan.md.
