## Buddy Activation Lifecycle

> **Last verified:** 2026-04-07 (commit 2cd4f2b). If you touch
> `modules/claude-code-buddy/default.nix`, the any-buddy worker
> invocation, the fingerprint scheme, or how cli.js gets patched
> and this fragment isn't updated in the same commit, stop and
> fix it.

When a user configures `programs.claude-code.buddy = { ... }`
(canonical) or `ai.claude.buddy = { ... }` (fanout from
`modules/ai/default.nix`), an HM activation script runs on every
`home-manager switch`. It computes a fingerprint, compares to the
stored one, and on mismatch: refreshes a writable cli.js copy,
runs the any-buddy worker, patches the salt into cli.js, and
resets the companion field in `~/.claude.json`.

### Fingerprint inputs

The fingerprint is `sha256sum` of a newline-separated concatenation
of:

1. The store path of `baseClaudeCode/lib/node_modules/@anthropic-ai/claude-code`
   (so a claude-code version bump invalidates)
2. The resolved `$USER_ID` (from `userId.text` or
   `cat $USER_ID_FILE`)
3. `buddy.species`
4. `buddy.rarity`
5. `buddy.eyes`
6. `buddy.hat`
7. `shiny` flag (string "true" or empty)
8. `buddy.peak` (or empty when null)
9. `buddy.dump` (or empty when null)

Only the first 16 hex chars of the sha256 are stored. Stored at
`$XDG_STATE_HOME/claude-code-buddy/fingerprint`.

**If fingerprint matches, the script exits 0 immediately.** The
entire downstream pipeline is skipped. This is why re-running
`home-manager switch` with unchanged config is fast.

### Invalidation triggers

The fingerprint changes (triggering re-run) on:

| Trigger                                                   | Why                                   |
| --------------------------------------------------------- | ------------------------------------- |
| First activation                                          | No fingerprint exists yet             |
| Any `buddy.*` option change                               | Direct input to the hash              |
| `claude-code` version upgrade                             | Store path is an input                |
| sops-decrypted UUID file content change                   | `userId.file` read at activation time |
| Manual `rm $XDG_STATE_HOME/claude-code-buddy/fingerprint` | Forces re-run                         |

Explicitly NOT triggering:

- User manually edits `cli.js` in the state dir (fingerprint only
  tracks inputs, not outputs)
- User manually edits `~/.claude.json` `companion` field (runtime
  state, not tracked)
- claude-code autoupdate (if enabled) replaces the store — would
  trigger, but our package pins via nvfetcher so autoupdate doesn't
  normally happen

### What the activation script does on re-run

1. **Resolve userId**: from `userId.text` (literal) or
   `userId.file` (sops path). File case uses `tr -d '\n\r'` to
   strip trailing whitespace. If file doesn't exist, errors out
   with a pointer to sops-nix ordering.
2. **Fresh writable lib tree**: `rm -rf $STATE_DIR/lib`, `mkdir`,
   `cp -rs $STORE_LIB/* $STATE_DIR/lib/` (symlink tree to store),
   `chmod -R u+w`. Most files stay as symlinks into the nix store
   (read-only but discoverable).
3. **Real cli.js copy**: `rm $STATE_DIR/lib/cli.js` (the symlink
   created in step 2), `cp -L $STORE_LIB/cli.js $STATE_DIR/lib/cli.js`
   (real file), `chmod u+w`. Now cli.js is a writable copy, siblings
   are still store symlinks.
4. **Salt search**: `bun ${any-buddy}/src/finder/worker.ts
"$USER_ID" species rarity eyes hat shiny peak dump | jq -r .salt`.
   Worker brute-forces a 15-char salt that hashes (via wyhash under
   Bun) to the desired traits. Validates output is 15 chars matching
   `[a-zA-Z0-9_-]`.
5. **Patch cli.js**: python3 binary-safe replace of `b'friend-2026-401'`
   with the new salt. The marker is 15 bytes, the salt is 15 bytes
   (constrained by the regex validation), so byte length is preserved.
6. **Reset companion**: if `~/.claude.json` exists, `jq 'del(.companion)'`
   through a temp file. Otherwise skipped (first-run case).
7. **Save fingerprint**: write the new 16-char hash to
   `$STATE_DIR/fingerprint`.

### Why the companion reset matters

`~/.claude.json` `companion` field is set by claude-code on first
hatch and cached across runs. It contains the buddy traits derived
from the current salt. If you change the salt (by changing buddy
options) but leave the cached companion alone, claude-code happily
keeps showing the OLD buddy because its runtime lookup hits the
cache before re-running the hash.

So the activation script MUST reset companion on every fingerprint
mismatch. Otherwise users think their config didn't take effect.

### Common failure modes

**"cannot coerce null to a string"** during activation eval:
`peakArg` or `dumpArg` was null and hit `"${null}"` interpolation.
Nix `or ""` doesn't catch null, only missing attributes. Fix is
explicit `if cfg.peak == null then "" else cfg.peak`. Landed in
commit 753ec43. If it recurs, check whether any other nullable
buddy option is being string-interpolated without a null guard.

**`programs.claude-code.buddy = null` despite `ai.claude.buddy`
being set**: the `ai.*` fanout block in `modules/ai/default.nix`
used to be gated on `mkIf cfg.enable` (where `cfg = config.ai`),
requiring `ai.enable = true` in addition to `ai.claude.enable`.
Users who only set `ai.claude.enable` got a silent no-op — the
buddy config was stored in the option but never fanned out.
Dropped the master switch in commit f2e911c. If it recurs, verify
the fanout block is NOT gated on anything except
`cfg.claude.enable`.

**Salt search returns a buddy that's not what you configured**:
hash-function mismatch between the worker and the runtime. Worker
runs under Bun (wyhash). Runtime must ALSO run under Bun (via the
wrapper chain — see `claude-code-wrapper` fragment). If the wrapper
got bypassed and claude ran under Node, the runtime uses fnv1a and
the salt produces a different buddy.

**State dir corruption**: `cp -rs` leaves a symlink tree into the
store. If the underlying store paths get GC'd (rare, only if
`claude-code` is uninstalled then a GC runs), the symlinks break.
`rm -rf $XDG_STATE_HOME/claude-code-buddy/` and re-run
`home-manager switch` — activation script rebuilds from scratch.

### Verifying activation worked

After `home-manager switch`:

1. `ls $XDG_STATE_HOME/claude-code-buddy/fingerprint` — exists
2. `cat $XDG_STATE_HOME/claude-code-buddy/lib/cli.js | head -1` —
   real file, not a broken symlink
3. `grep -c friend-2026-401 $XDG_STATE_HOME/claude-code-buddy/lib/cli.js`
   — should be 0 (old marker replaced with new salt)
4. `jq .companion ~/.claude.json` — should be `null` until next
   claude launch
5. Launch claude. `/buddy` should show the configured species.

### Not here

Wrapper chain, why Bun, `baseClaudeCode` passthru: see
`claude-code-wrapper` fragment in this same directory.

`ai.claude.buddy` fanout mechanics and the ai module's per-CLI
gating: see `ai-module-fanout` fragment under `modules/ai/`.
