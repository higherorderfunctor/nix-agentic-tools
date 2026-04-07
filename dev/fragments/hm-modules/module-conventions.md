## HM Module Conventions

> **Last verified:** 2026-04-07 (commit adce79e). If you touch
> any `modules/<subdir>/default.nix` file, add a new option, or
> change an assertion/activation pattern and this fragment isn't
> updated in the same commit, stop and fix it.

These conventions are enforced by code review and the
`checks/module-eval.nix` evaluation tests, not by the module
system itself. Follow them when adding or modifying any HM module
under `modules/**`.

### Option shape conventions

**Use explicit types.** Rare `types.anything` appears only as an
`internal = true` escape hatch in the MCP module's `mcpConfig`.
Everywhere else, declare the real type: `types.submodule`,
`types.nullOr`, `types.attrsOf`, `types.enum`, `types.attrTag`
(for mutually exclusive variants like the buddy `userId.text`
XOR `userId.file` discriminated union), `types.listOf`, etc.

**Submodules as containers.** Per-ecosystem config lives in a
submodule: `ai.claude`, `ai.copilot`, `ai.kiro` are each a
`types.submodule { options = { enable; package; ... }; }`. The
submodule is the logical grouping — do not flatten per-ecosystem
options into the top level.

**Flat at top level for cross-ecosystem.** `ai.skills`,
`ai.instructions`, `ai.lspServers`, `ai.settings`, and
`ai.environmentVariables` are NOT nested inside a per-ecosystem
submodule. They fan out to whichever ecosystems are enabled at
`mkDefault` priority. Anything that's "one option, many
destinations" lives flat.

**Settings pattern: freeformType + typed subkeys.** When wrapping
a CLI's settings.json, use `freeformType = jsonFormat.type` plus
explicit `mkOption` declarations for known typed keys (e.g.
`settings.model`, `settings.telemetry`). Unknown keys flow
through freely; known keys get type-checked.

**Defaults via `mkOption { default = ...; }`**, not `mkDefault`
in the declaration. Reserve `mkDefault` for fanout values in the
config block (so consumers can override).

### Gating and mkIf patterns

**Per-CLI enable is the SOLE gate.** Each `ai.{claude,copilot,kiro}.enable`
is its own mkIf block. There is **no master `ai.enable`** — it
was dropped in commit f2e911c after causing a silent no-op bug
(see `ai-module-fanout` fragment for the full story).

The `config` block shape:

```nix
config = mkMerge [
  { assertions = [...]; }                # Always evaluated
  (mkIf cfg.claude.enable  { ... })      # Each CLI independent
  (mkIf cfg.copilot.enable { ... })
  (mkIf cfg.kiro.enable    { ... })
];
```

**Each per-CLI block also flips the corresponding
`programs.<cli>.enable`:**

```nix
(mkIf cfg.claude.enable {
  programs.claude-code.enable = mkDefault true;
  # ... rest of claude fanout
})
```

`mkDefault` lets the consumer override with `programs.claude-code.enable = false`
explicitly if they want to turn it off while keeping `ai.claude.enable = true`
for other reasons. In practice they don't — it's an escape hatch.

**hasModule checks upstream availability**:

```nix
hasModule = path: (attrByPath path null options) != null;
```

This queries the OPTION space, not the config values. Used in
assertions to verify `programs.copilot-cli.enable` exists as an
option path before trying to reference it. Different from runtime
checks — runs at eval time.

**Nested mkIf for conditional fanout:**

```nix
(mkIf (cfg.lspServers != {} && hasModule ["programs" "claude-code" "settings"]) {
  programs.claude-code.settings.env.ENABLE_LSP_TOOL = mkDefault "1";
})
```

Check both the data condition (`lspServers != {}`) and the module
availability (`hasModule ...`) before touching an upstream option
path. Keeps the module robust to consumers who haven't imported
everything.

### Assertion conventions

**Always outside mkIf.** Assertions live in an unguarded block
inside `mkMerge [...]`. This ensures misconfigurations surface
even when the feature itself isn't enabled:

```nix
config = mkMerge [
  {
    assertions = [
      { assertion = cfg.copilot.enable -> hasModule ["programs" "copilot-cli" "enable"];
        message = "ai.copilot.enable requires programs.copilot-cli to be available."; }
      # ...
    ];
  }
  # ... mkIf blocks ...
];
```

**Precise messages naming the option path.** Don't say "module
error" or "configuration invalid." Say
`ai.copilot.enable requires programs.copilot-cli to be available`.

**Data-dependent assertions use lib.optionals + implication.**
Example from the buddy assertions:

```nix
assertions =
  [{ assertion = ...; message = ...; }]
  ++ (optionals (cfg.claude.buddy != null) [
    { assertion = cfg.claude.buddy.peak != cfg.claude.buddy.dump || cfg.claude.buddy.peak == null;
      message = "ai.claude.buddy: peak and dump stats must differ"; }
    { assertion = cfg.claude.buddy.rarity == "common" -> cfg.claude.buddy.hat == "none";
      message = "ai.claude.buddy: common rarity forces hat = \"none\""; }
  ]);
```

The `optionals` wrapper only runs the inner assertions when
`buddy != null`, so the per-field references don't fail on
unset buddy config.

### Package override pattern

**Every per-CLI submodule exposes a `package` option.** Consumers
can swap out the package entirely. Wrapping pattern (claude-code,
copilot-cli, kiro-cli):

```nix
pkgs.symlinkJoin {
  name = "<cli>-wrapped";
  paths = [cfg.package];
  postBuild = ''
    mv $out/bin/<cli> $out/bin/.<cli>-wrapped
    cat > $out/bin/<cli> << 'WRAPPER'
    #!/usr/bin/env bash
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    # ...env exports, path setup, etc.
    exec "$out/bin/.<cli>-wrapped" "$@"
    WRAPPER
    chmod +x $out/bin/<cli>
  '';
}
```

**passthru.baseClaudeCode escape hatch.** The claude-code wrap
exposes the unwrapped nixpkgs derivation as
`passthru.baseClaudeCode` so downstream modules (buddy activation
script) can find the real `cli.js` in the store. See
`claude-code-wrapper` fragment for the full chain.

### Activation script patterns

**Location and ordering:**

```nix
home.activation.<name> = lib.hm.dag.entryAfter ["writeBoundary"] (script);
```

All activation scripts run `entryAfter ["writeBoundary"]`, meaning
after HM has written all files to the home directory. No use of
`entryBefore` in this repo.

**Fingerprint caching pattern** (buddy activation, see
`buddy-activation` fragment): compute sha256 of inputs, compare
to stored marker, exit early if unchanged. Re-running
`home-manager switch` with unchanged config becomes a no-op.

**Settings merge pattern** (copilot-cli, kiro-cli): runtime
config.json files are merged with Nix-declared values using
`jq -s '.[0] * .[1]'` so user runtime edits (e.g.,
`trusted_folders`) are preserved across rebuilds. The Nix
settings override on conflict, user-added keys pass through.

**Secrets at activation time, not eval time.** Sops-nix paths
(`cfg.userId.file`) are read by the activation script at run
time via `cat "$path"`. Do NOT `builtins.readFile` them at
eval time — sops decryption happens after nix eval finishes.

### home.file vs home.activation vs outOfStoreSymlink

**`home.file` with `source =`** — immutable store-backed content.
Used for skills directory symlinks and static config files. If
the content is already in the store (a derivation output, a
file inside the flake), this is the right tool.

**`home.file` with `text =`** — content built at eval time from
Nix data. Used for transformed instructions (e.g., the
`fragments-ai` transforms emit strings that become
`home.file.".claude/rules/<name>.md".text`).

**`home.activation`** — stateful operations that need runtime
info: reading sops files, computing fingerprints, merging
runtime-mutable config files, resetting cached state.

**`outOfStoreSymlink`** is NOT used in this repo's modules. See
the backlog item about runtime state dirs for Claude's
`~/.claude/projects`, which would need it.

**Runtime-mutable files** like `~/.claude.json` (buddy companion
field written by claude at runtime) are NOT managed by HM. The
buddy activation script only RESETS the companion field on
fingerprint mismatch, letting claude re-hatch on next launch.

### Config parity rule (HM ↔ devenv)

**Every option on an HM module under `modules/<subdir>/` MUST
have a matching option on the corresponding devenv module under
`modules/devenv/<subdir>.nix`** — same types, same semantics,
same fanout behavior. If you add an option to one, add it to
the other in the same commit. Enforced by convention, checked
at code review.

**Shared types live in `lib/`.** Both HM and devenv modules import
types from `lib/buddy-types.nix` (`buddySubmodule`) and
`lib/ai-common.nix` (`instructionModule`, `lspServerModule`,
`mkCopilotLspConfig`, `mkLspConfig`) so the surfaces stay in
sync by construction.

**Intentional differences** exist and are NOT parity gaps:

- `ai.claude.buddy` is HM-only (per-user, needs ~/.claude.json
  which devenv doesn't touch)
- Activation scripts are HM-only (devenv lifecycle is different)
- HM uses `home.file` / `home.activation`; devenv uses `files.*`
  (per-project writable tree, not home dir)

If you touch one and the other is "intentionally different," say
so in the commit message. If the mismatch is accidental, it's a
bug.

### Validation

`checks/module-eval.nix` runs module evaluation tests via
`evalModule` with the full `homeManagerModules.default` set.
Add test cases there whenever you add new module behavior —
especially for:

- Option discoverability (set an option, verify it evaluates)
- Fanout correctness (set `ai.claude.buddy`, verify
  `programs.claude-code.buddy` becomes non-null)
- Assertion firing (intentionally misconfigure, verify the
  right assertion triggers)

The tests caught the `ai.enable` master-switch bug during
the f2e911c fix because the post-fix tests didn't reference
`ai.enable` anymore. Regression protection via the eval harness.
